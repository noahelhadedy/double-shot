import DoubleShotCore
import Foundation
import Observation

/// Notices when AI coding agents are working, with no setup from the user.
/// Agents the user added by name in Settings count for as long as they run.
///
/// A session counts as working when:
/// - it's a one-shot background run (`claude -p`, `codex exec`) that showed any sign of life in
///   the last 20 minutes, since such a run works until it exits, or
/// - in the last check it used real CPU itself or through the tool calls it started, or
/// - it wrote its session log in the last 90 seconds (Claude Code logs per working directory,
///   so each session gets its own; for other agents a write counts for all their sessions).
/// Cursor IDE chat and the Agents window are the `extension-host (agent-exec)` helpers; the
/// `cursor-agent` CLI still counts too. Idle Cursor shell hosts are ignored. Transcript files under
/// `agent-transcripts` that end with `turn_ended` do **not** count (that write means the run
/// finished). A working latch (2.5 minutes by default) bridges quiet gaps between tool calls.
/// Each session is judged on its own, and its helpers (MCP servers, browsers, language
/// servers) are left out, so an open session waiting for input lets the Mac sleep.
@MainActor
@Observable
final class AgentMonitor {
    struct Status: Identifiable, Equatable {
        let kind: AgentKind
        var sessions: Int
        /// One-shot runs among the sessions.
        var backgroundRuns: Int
        var isWorking: Bool
        var id: String { kind.id }
    }

    /// Agents with at least one running process, in catalog order.
    private(set) var running: [Status] = []
    private(set) var isAnyWorking = false
    private(set) var lastWorkingAt: Date?

    @ObservationIgnored var onUpdate: (() -> Void)?
    /// Agents the user added by name in Settings, on top of the catalog.
    @ObservationIgnored var customAgents: [String] = [] {
        didSet { kinds = AgentKind.all + Self.uniqueCustomKinds(customAgents) }
    }
    @ObservationIgnored private var kinds = AgentKind.all

    private static func uniqueCustomKinds(_ names: [String]) -> [AgentKind] {
        var seen: Set<String> = []
        return names.compactMap(AgentKind.custom).filter { seen.insert($0.id).inserted }
    }

    private static let interval: TimeInterval = 10
    /// Share of one CPU core a session needs to count as busy.
    private static let busyCPUShare = 0.10
    /// How long a log write keeps counting as activity.
    private static let logWindow: TimeInterval = 90
    /// A background run with no sign of life for this long is stuck, not working.
    private static let backgroundStaleAfter: TimeInterval = 20 * 60
    /// CPU seconds per check that count as a sign of life for that clock. A run hung on the network
    /// still ticks over at about 0.03 s.
    private static let signOfLifeCPU = 0.3
    /// What a session starts this soon after it launches is a server (MCP), not a tool call.
    private static let helperStartWindow: TimeInterval = 60
    private static let helperNames = ["Google Chrome", "Chromium", "chrome-headless-shell", "chrome", "Electron",
                                      "language-server", "tsserver", "sourcekit-lsp", "rust-analyzer", "gopls"]
    /// Agents run their tool calls through a shell, servers are started directly. A shell is never a helper.
    private static let shellNames: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "nu"]
    /// A tool call that is still running counts as work even with no CPU (a docker build, a download,
    /// `gh run watch`), up to this age; older ones are background servers left running.
    private static let toolCallWindow: TimeInterval = 30 * 60
    /// A log file nobody wrote to for this long is a finished session, stop checking it.
    private static let trackedFileLifetime: TimeInterval = 6 * 60 * 60

    /// After real activity, keep counting as working this long with no new signal.
    /// Overridable for `--probe-agents --latch=0` and tests. Production default is 2.5 minutes.
    @ObservationIgnored var workingLatch: TimeInterval = AgentActivityRules.defaultWorkingLatch

    /// A process is identified by pid plus start time, so a reused pid is never mixed up.
    private struct ProcessKey: Hashable {
        let pid: pid_t
        let start: Double
    }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastCheckAt: Date?
    @ObservationIgnored private var lastCPU: [ProcessKey: Double] = [:]
    @ObservationIgnored private var lastLogWrite: [String: Date] = [:]
    /// Last write per project log folder, for agents with `logsPerProject`.
    @ObservationIgnored private var lastProjectWrite: [String: Date] = [:]
    /// Log files seen being written and when they last changed. FSEvents only reports a file an
    /// agent keeps open (Codex's session log, Cursor's database) when it's created and closed,
    /// so each check looks at these files for writes in between.
    @ObservationIgnored private var trackedFiles: [String: Date] = [:]
    @ObservationIgnored private var argumentsCache: [ProcessKey: [String]] = [:]
    @ObservationIgnored private var lastActive: [ProcessKey: Date] = [:]
    /// Last time a session showed real work (CPU, an active tool, or a log write). Used for latching.
    @ObservationIgnored private var lastBusyAt: [ProcessKey: Date] = [:]
    @ObservationIgnored private lazy var watcher = FolderWatcher { [weak self] path in
        self?.noteWrite(at: path)
    }

    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        trackRecentLogFiles()
        // The first check only takes a CPU baseline, so it never reports work
        DispatchQueue.main.async { [weak self] in self?.check() }
    }

    /// Prints what the monitor sees for `DoubleShot --probe-agents`.
    /// Pass `watch: true` (or `--watch`) to keep checking and print only when status changes.
    /// `interval` defaults to 2s for debugging; override with `--interval=5` (seconds).
    /// `latch` overrides the working latch (`--latch=0` disables it for scenario tests).
    static func probeAndExit(watch: Bool = false, interval: TimeInterval = 2, latch: TimeInterval? = nil) {
        let interval = max(interval, 0.5)
        let monitor = AgentMonitor()
        if let latch { monitor.workingLatch = max(0, latch) }
        monitor.trackRecentLogFiles()
        monitor.check() // CPU baseline only
        Thread.sleep(forTimeInterval: min(interval, 1.2))
        monitor.check()
        var previous = monitor.probeSnapshot()
        print(Self.probeLine(previous, changed: false, latch: monitor.workingLatch))

        guard watch else { exit(0) }

        let label = interval == floor(interval) ? "\(Int(interval))s" : String(format: "%.1fs", interval)
        let latchLabel = monitor.workingLatch == 0 ? "off" : String(format: "%.0fs", monitor.workingLatch)
        print("Watching every \(label) (latch \(latchLabel)) — Ctrl+C to stop.")
        fflush(stdout)
        while true {
            Thread.sleep(forTimeInterval: interval)
            monitor.check()
            let current = monitor.probeSnapshot()
            guard current != previous else { continue }
            previous = current
            print(Self.probeLine(current, changed: true, latch: monitor.workingLatch))
            fflush(stdout)
        }
    }

    private struct ProbeSnapshot: Equatable {
        var isAnyWorking: Bool
        var lines: [String]
    }

    private func probeSnapshot() -> ProbeSnapshot {
        let lines = running.map { status -> String in
            let state = status.kind.countsUntilExit ? "running"
                : status.backgroundRuns > 0 ? "background"
                : status.isWorking ? "working" : "idle"
            return "\(status.kind.name) sessions=\(status.sessions) background=\(status.backgroundRuns) \(state)"
        }
        return ProbeSnapshot(isAnyWorking: isAnyWorking, lines: lines)
    }

    private static func probeLine(_ snapshot: ProbeSnapshot, changed: Bool, latch: TimeInterval) -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let prefix = changed ? "changed" : "status"
        let agents = snapshot.lines.isEmpty ? "none" : snapshot.lines.joined(separator: "; ")
        let latchNote = latch == 0 ? " latch=off" : ""
        return "[\(stamp)] \(prefix) isAnyWorking=\(snapshot.isAnyWorking)\(latchNote) — \(agents)"
    }

    func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        watcher.stop()
        running = []
        isAnyWorking = false
        lastCPU = [:]
        lastCheckAt = nil
        // Writes made while stopped aren't news when it starts again
        trackedFiles = [:]
    }

    /// Files agents already had open before we started (after an update, or turning agents back on):
    /// FSEvents won't mention them until they're closed, so look for recently changed ones once.
    private func trackRecentLogFiles() {
        let since = Date().addingTimeInterval(-Self.trackedFileLifetime)
        for kind in AgentKind.all {
            for folder in logFolders(of: kind) {
                guard let files = FileManager.default.enumerator(at: URL(fileURLWithPath: folder),
                                                                 includingPropertiesForKeys: [.contentModificationDateKey],
                                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let file as URL in files where kind.logSuffixes.contains(where: file.path.hasSuffix) {
                    guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                          modified > since else { continue }
                    trackedFiles[file.path] = modified
                }
            }
        }
    }

    private func resolvedHomePath(_ relative: String) -> String {
        // Resolved, because FSEvents reports real paths even when the folder is a symlink
        URL(fileURLWithPath: "\(home)/\(relative)").resolvingSymlinksInPath().path
    }

    private func logFolders(of kind: AgentKind) -> [String] {
        var folders = kind.logFolders.map(resolvedHomePath(_:))
        // Cursor IDE chats: ~/.cursor/projects/<workspace>/agent-transcripts
        if let nested = kind.nestedLogFolderName {
            for root in kind.nestedLogRoots.map(resolvedHomePath(_:)) {
                guard let children = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
                for child in children where !child.hasPrefix(".") {
                    let path = "\(root)/\(child)/\(nested)"
                    if FileManager.default.fileExists(atPath: path) { folders.append(path) }
                }
            }
        }
        return folders
    }

    /// The agents whose session log this is, with the log folder it's in. Only session logs
    /// count, not memory notes or other files in those folders.
    private func owners(of path: String) -> [(kind: AgentKind, folder: String)] {
        guard !path.contains("/memory/") else { return [] }
        return AgentKind.all.compactMap { kind in
            guard kind.logSuffixes.contains(where: path.hasSuffix),
                  let folder = logFolders(of: kind).first(where: { path.hasPrefix($0 + "/") }) else { return nil }
            return (kind, folder)
        }
    }

    private func noteWrite(at path: String) {
        let owners = owners(of: path)
        guard !owners.isEmpty else { return }
        trackedFiles[path] = Self.modificationDate(of: path) ?? Date()
        guard Self.shouldCountLogActivity(at: path) else { return }
        for owner in owners { recordWrite(of: owner.kind, folder: owner.folder, path: path, at: Date()) }
    }

    private func recordWrite(of kind: AgentKind, folder: String, path: String, at date: Date) {
        lastLogWrite[kind.id] = date
        if kind.logsPerProject, let project = path.dropFirst(folder.count + 1).split(separator: "/").first {
            lastProjectWrite[folder + "/" + project] = date
        }
    }

    /// Cursor agent-transcripts ending in `turn_ended` mean the run finished — not activity.
    private static func shouldCountLogActivity(at path: String) -> Bool {
        let lastLine = path.contains("/agent-transcripts/")
            ? AgentActivityRules.lastNonEmptyLine(of: path) : nil
        return AgentActivityRules.shouldCountLogWrite(path: path, lastLine: lastLine)
    }

    /// Writes FSEvents didn't report, to files that stay open.
    private func checkTrackedFiles(now: Date) {
        lastProjectWrite = lastProjectWrite.filter { now.timeIntervalSince($0.value) < Self.logWindow }
        for (path, seen) in trackedFiles {
            guard let modified = Self.modificationDate(of: path),
                  now.timeIntervalSince(modified) < Self.trackedFileLifetime else {
                trackedFiles[path] = nil
                continue
            }
            guard modified > seen else { continue }
            trackedFiles[path] = modified
            guard Self.shouldCountLogActivity(at: path) else { continue }
            // When the file changed, not when we noticed (the first check after a wake can be late)
            for owner in owners(of: path) { recordWrite(of: owner.kind, folder: owner.folder, path: path, at: min(modified, now)) }
        }
    }

    /// The log folder of the session running in `pid`, when the agent keeps one per working
    /// directory and it exists. Claude names it after the path with every UTF-16 unit that isn't
    /// a letter or digit as a dash, and cuts names over 200 characters, adding a short hash.
    private func projectLogFolder(of kind: AgentKind, pid: pid_t) -> String? {
        guard kind.logsPerProject, let directory = Self.workingDirectory(of: pid) else { return nil }
        // Claude uses the composed form (é as one character); paths made by Finder come decomposed
        let name = String(directory.precomposedStringWithCanonicalMapping.utf16.map { unit -> Character in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: Character(UnicodeScalar(UInt8(unit)))
            default: "-"
            }
        })
        for folder in logFolders(of: kind) {
            let path = "\(folder)/\(name)"
            if FileManager.default.fileExists(atPath: path) { return path }
            guard name.count > 200 else { continue }
            let prefix = String(name.prefix(200)) + "-"
            let match = (try? FileManager.default.contentsOfDirectory(atPath: folder))?.first { $0.hasPrefix(prefix) }
            if let match { return "\(folder)/\(match)" }
        }
        return nil
    }

    private func check() {
        // Folders may appear after the first run of an agent, so re-check which exist
        let existing = AgentKind.all.flatMap(logFolders(of:)).filter { FileManager.default.fileExists(atPath: $0) }
        watcher.watch(existing)

        let now = Date()
        checkTrackedFiles(now: now)
        let elapsed = min(max(now.timeIntervalSince(lastCheckAt ?? now), 1), 60)
        let previousCheck = lastCheckAt?.timeIntervalSince1970
        let table = ProcessTable.snapshot()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        func key(_ entry: ProcessTable.Entry) -> ProcessKey { ProcessKey(pid: entry.pid, start: entry.startTime) }

        var liveArguments: [ProcessKey: [String]] = [:]
        func arguments(_ entry: ProcessTable.Entry) -> [String] {
            let k = key(entry)
            let value = liveArguments[k] ?? argumentsCache[k] ?? ProcessTable.arguments(of: entry.pid) ?? []
            liveArguments[k] = value
            return value
        }

        // Process names that need argv for IDE helpers (Cursor sets argv[0] to the window title)
        let argumentProbeNames = Set(kinds.flatMap(\.argumentProbeNames))

        // Find agent processes
        var rootsByKind: [String: [ProcessTable.Entry]] = [:]
        for entry in table.entries.values where entry.pid != ownPID {
            let isInterpreter = AgentKind.isInterpreter(entry.name)
            let needsArgs = isInterpreter || argumentProbeNames.contains(entry.name)
            let path = isInterpreter ? nil : Self.executablePath(of: entry.pid)
            let argv = needsArgs ? arguments(entry) : nil
            for kind in kinds where kind.matches(name: entry.name, path: path, arguments: argv) {
                if kind.isService(argv ?? arguments(entry)) { continue }
                rootsByKind[kind.id, default: []].append(entry)
            }
        }

        // CPU one process used since the last check
        func used(_ entry: ProcessTable.Entry) -> Double {
            if let previous = lastCPU[key(entry)] { return max(entry.cpuSeconds - previous, 0) }
            // Started after the last check: all of its CPU is new work
            if let previousCheck, entry.startTime > previousCheck { return entry.cpuSeconds }
            return 0
        }

        var statuses: [Status] = []
        var liveActive: [ProcessKey: Date] = [:]
        for kind in kinds {
            guard let roots = rootsByKind[kind.id], !roots.isEmpty else { continue }
            let rootPIDs = Set(roots.map(\.pid))
            // Top level sessions only, not an agent's own helper processes
            let sessions = roots.filter { !rootPIDs.contains($0.parent) }
            let wroteLogs = lastLogWrite[kind.id].map { now.timeIntervalSince($0) < Self.logWindow } ?? false

            var anyBusy = false
            var anyWrote = false
            var anyLatched = false
            var backgroundRuns = 0
            for session in sessions {
                // MCP servers start with the session, browsers and language servers by name; a long
                // build started later still counts. The agent's own processes are never helpers: npm
                // Codex and Gemini CLI start the real agent as a child right away.
                let isHelper: (ProcessTable.Entry) -> Bool = { entry in
                    guard !Self.shellNames.contains(entry.name), !rootPIDs.contains(entry.pid) else { return false }
                    return entry.startTime - session.startTime < Self.helperStartWindow
                        || Self.helperNames.contains { entry.name.localizedCaseInsensitiveContains($0) }
                }
                let tree = table.tree(of: session.pid, skip: isHelper).compactMap { table.entries[$0] }
                let cpu = tree.reduce(0) { $0 + used($1) }
                // A bare shell is not enough: Cursor keeps an idle zsh host under agent-exec between
                // commands (and sometimes after a turn). Count it only when the shell is using CPU
                // or has a real child (python, sleep, docker, …).
                let runningToolCall = tree.contains { entry in
                    guard entry.pid != session.pid, Self.shellNames.contains(entry.name),
                          now.timeIntervalSince1970 - entry.startTime < Self.toolCallWindow else { return false }
                    let shellTree = table.tree(of: entry.pid).compactMap { table.entries[$0] }
                    let shellCPU = shellTree.reduce(0) { $0 + used($1) }
                    let hasToolChild = shellTree.contains {
                        $0.pid != entry.pid && !AgentActivityRules.shellNames.contains($0.name)
                    }
                    return AgentActivityRules.toolShellIsActive(
                        shellCPUSeconds: shellCPU,
                        elapsed: elapsed,
                        busyCPUShare: Self.busyCPUShare,
                        hasNonShellChild: hasToolChild
                    )
                }
                let busy = cpu / elapsed >= Self.busyCPUShare || runningToolCall
                anyBusy = anyBusy || busy
                // Its own log folder when it has one, so another session's writes don't count for it
                let ownWrote = projectLogFolder(of: kind, pid: session.pid).map { folder in
                    lastProjectWrite[folder].map { now.timeIntervalSince($0) < Self.logWindow } ?? false
                }
                // No folder yet (Claude makes it on the first prompt): any write of this agent counts as
                // work, but never keeps a background run alive, a stuck run would never go stale
                anyWrote = anyWrote || (ownWrote ?? wroteLogs)
                let signOfLife = busy || cpu > Self.signOfLifeCPU || (kind.logsPerProject ? ownWrote == true : wroteLogs)

                let sessionKey = key(session)
                let active = signOfLife ? now : (lastActive[sessionKey] ?? now)
                liveActive[sessionKey] = active
                if signOfLife { lastBusyAt[sessionKey] = now }
                let latched = AgentActivityRules.isLatched(
                    lastBusyAt: lastBusyAt[sessionKey], now: now, latch: workingLatch
                )
                anyLatched = anyLatched || latched
                // An agent the user added has no logs to judge it by, and one waiting on its model barely
                // uses CPU, so it counts until it exits
                if kind.isBackgroundRun(arguments(session)),
                   kind.countsUntilExit || now.timeIntervalSince(active) < Self.backgroundStaleAfter {
                    backgroundRuns += 1
                }
            }
            let wrote = sessions.isEmpty ? wroteLogs : anyWrote
            statuses.append(Status(kind: kind, sessions: max(sessions.count, 1), backgroundRuns: backgroundRuns,
                                   isWorking: AgentActivityRules.isWorking(
                                    busy: anyBusy, latched: anyLatched, wroteLogs: wrote, backgroundRuns: backgroundRuns
                                   )))
        }

        var cpuNow: [ProcessKey: Double] = [:]
        for entry in table.entries.values { cpuNow[key(entry)] = entry.cpuSeconds }
        lastCPU = cpuNow
        lastCheckAt = now
        argumentsCache = liveArguments
        lastActive = liveActive
        lastBusyAt = lastBusyAt.filter { liveActive.keys.contains($0.key) }

        let working = statuses.contains { $0.isWorking }
        if working { lastWorkingAt = now }
        if statuses != running { running = statuses }
        if working != isAnyWorking {
            Log.agents.notice("Agents working: \(working), running: \(statuses.map { "\($0.kind.name) x\($0.sessions)" }.joined(separator: ", "), privacy: .public)")
            isAnyWorking = working
        }
        onUpdate?()
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    private static func modificationDate(of path: String) -> Date? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
