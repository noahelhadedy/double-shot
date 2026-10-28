import Foundation
import Observation

/// Notices when AI coding agents are working, with no setup from the user.
///
/// A session counts as working when:
/// - it's a one-shot background run (`claude -p`, `codex exec`) that showed any sign of life in
///   the last 20 minutes, since such a run works until it exits, or
/// - in the last check it used real CPU itself or through the tool calls it started, or
/// - its agent wrote a session log in the last 90 seconds.
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

    private static let interval: TimeInterval = 10
    /// Share of one CPU core a session needs to count as busy.
    private static let busyCPUShare = 0.10
    /// How long a log write keeps counting as activity.
    private static let logWindow: TimeInterval = 90
    /// A background run with no sign of life for this long is stuck, not working.
    private static let backgroundStaleAfter: TimeInterval = 20 * 60
    /// What a session starts this soon after it launches is a server (MCP), not a tool call.
    private static let helperStartWindow: TimeInterval = 60
    private static let helperNames = ["Google Chrome", "Chromium", "chrome-headless-shell", "chrome", "Electron",
                                      "language-server", "tsserver", "sourcekit-lsp", "rust-analyzer", "gopls"]
    /// Agents run their tool calls through a shell, servers are started directly. A shell is never a helper.
    private static let shellNames: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "nu"]
    /// A tool call that is still running counts as work even with no CPU (a docker build, a download,
    /// `gh run watch`), up to this age; older ones are background servers left running.
    private static let toolCallWindow: TimeInterval = 30 * 60

    /// A process is identified by pid plus start time, so a reused pid is never mixed up.
    private struct ProcessKey: Hashable {
        let pid: pid_t
        let start: Double
    }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastCheckAt: Date?
    @ObservationIgnored private var lastCPU: [ProcessKey: Double] = [:]
    @ObservationIgnored private var lastLogWrite: [String: Date] = [:]
    @ObservationIgnored private var argumentsCache: [ProcessKey: [String]] = [:]
    @ObservationIgnored private var lastActive: [ProcessKey: Date] = [:]
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
        // The first check only takes a CPU baseline, so it never reports work
        DispatchQueue.main.async { [weak self] in self?.check() }
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
    }

    private func logFolders(of kind: AgentKind) -> [String] {
        // Resolved, because FSEvents reports real paths even when the folder is a symlink
        kind.logFolders.map { URL(fileURLWithPath: "\(home)/\($0)").resolvingSymlinksInPath().path }
    }

    /// Only session logs count, not memory notes or other files in those folders.
    private func noteWrite(at path: String) {
        guard path.hasSuffix(".jsonl") || path.hasSuffix(".json"), !path.contains("/memory/") else { return }
        for kind in AgentKind.all where logFolders(of: kind).contains(where: { path.hasPrefix($0 + "/") }) {
            lastLogWrite[kind.id] = Date()
        }
    }

    private func check() {
        // Folders may appear after the first run of an agent, so re-check which exist
        let existing = AgentKind.all.flatMap(logFolders(of:)).filter { FileManager.default.fileExists(atPath: $0) }
        watcher.watch(existing)

        let now = Date()
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

        // Find agent processes
        var rootsByKind: [String: [ProcessTable.Entry]] = [:]
        for entry in table.entries.values where entry.pid != ownPID {
            let isInterpreter = AgentKind.isInterpreter(entry.name)
            let path = isInterpreter ? nil : Self.executablePath(of: entry.pid)
            let argv = isInterpreter ? arguments(entry) : nil
            for kind in AgentKind.all where kind.matches(name: entry.name, path: path, arguments: argv) {
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
        for kind in AgentKind.all {
            guard let roots = rootsByKind[kind.id], !roots.isEmpty else { continue }
            let rootPIDs = Set(roots.map(\.pid))
            // Top level sessions only, not an agent's own helper processes
            let sessions = roots.filter { !rootPIDs.contains($0.parent) }
            let wroteLogs = lastLogWrite[kind.id].map { now.timeIntervalSince($0) < Self.logWindow } ?? false

            var anyBusy = false
            var backgroundRuns = 0
            for session in sessions {
                // MCP servers start with the session, browsers and language servers by name; a long
                // build started later still counts
                let isHelper: (ProcessTable.Entry) -> Bool = { entry in
                    guard !Self.shellNames.contains(entry.name) else { return false }
                    return entry.startTime - session.startTime < Self.helperStartWindow
                        || Self.helperNames.contains { entry.name.localizedCaseInsensitiveContains($0) }
                }
                let tree = table.tree(of: session.pid, skip: isHelper).compactMap { table.entries[$0] }
                let cpu = tree.reduce(0) { $0 + used($1) }
                let runningToolCall = tree.contains { entry in
                    entry.pid != session.pid && Self.shellNames.contains(entry.name)
                        && now.timeIntervalSince1970 - entry.startTime < Self.toolCallWindow
                }
                let busy = cpu / elapsed >= Self.busyCPUShare || runningToolCall
                anyBusy = anyBusy || busy

                let sessionKey = key(session)
                let active = (busy || cpu > 0.05 || wroteLogs) ? now : (lastActive[sessionKey] ?? now)
                liveActive[sessionKey] = active
                if kind.isBackgroundRun(arguments(session)), now.timeIntervalSince(active) < Self.backgroundStaleAfter {
                    backgroundRuns += 1
                }
            }
            statuses.append(Status(kind: kind, sessions: max(sessions.count, 1), backgroundRuns: backgroundRuns,
                                   isWorking: anyBusy || wroteLogs || backgroundRuns > 0))
        }

        var cpuNow: [ProcessKey: Double] = [:]
        for entry in table.entries.values { cpuNow[key(entry)] = entry.cpuSeconds }
        lastCPU = cpuNow
        lastCheckAt = now
        argumentsCache = liveArguments
        lastActive = liveActive

        let working = statuses.contains { $0.isWorking }
        if working { lastWorkingAt = now }
        if statuses != running { running = statuses }
        if working != isAnyWorking {
            Log.agents.notice("Agents working: \(working), running: \(statuses.map { "\($0.kind.name) x\($0.sessions)" }.joined(separator: ", "), privacy: .public)")
            isAnyWorking = working
        }
        onUpdate?()
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
