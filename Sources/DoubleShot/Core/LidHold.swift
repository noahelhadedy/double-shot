import Foundation

/// Keeping a Mac awake with the lid shut needs `pmset disablesleep`, which only root can run.
/// A one-time sudoers rule lets this user run exactly four pmset commands without a password,
/// nothing else. The rule lives in /etc/sudoers.d/doubleshot and can be removed from Settings.
@MainActor
enum LidHold {
    static let ruleFile = "/etc/sudoers.d/doubleshot"

    private static let allowedCommands = [
        "/usr/bin/pmset -a disablesleep 1",
        "/usr/bin/pmset -a disablesleep 0",
        "/usr/bin/pmset -b lowpowermode 1",
        "/usr/bin/pmset -b lowpowermode 0",
    ]

    /// Whether a sudoers rule lets us run every command we use without a password.
    ///
    /// `sudo -n -l <command>` isn't enough: for an admin it also says yes through "(ALL) ALL",
    /// which still asks for a password, so the commands have to be listed under NOPASSWD.
    static var isSetUp: Bool {
        let listing = Shell.run("/usr/bin/sudo", ["-n", "-l"])
        guard listing.status == 0 else { return false }
        let allowed = passwordFreeCommands(in: listing.output)
        return allowedCommands.allSatisfy(allowed.contains)
    }

    /// Commands listed after a NOPASSWD tag in `sudo -l` output, entries like
    /// "(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0".
    static func passwordFreeCommands(in listing: String) -> Set<String> {
        // An entry starts with its runas list in parentheses; longer ones may wrap onto more lines
        var entries: [String] = []
        for line in listing.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("(") {
                entries.append(trimmed)
            } else if !trimmed.isEmpty, line.first?.isWhitespace == true, !entries.isEmpty {
                entries[entries.count - 1] += " " + trimmed
            }
        }
        var commands: Set<String> = []
        for entry in entries {
            guard let tag = entry.range(of: "NOPASSWD:") else { continue }
            for item in entry[tag.upperBound...].split(separator: ",") {
                let command = item.trimmingCharacters(in: .whitespaces)
                // Another tag (PASSWD:, SETENV:) changes the rules for what follows
                if command.contains(":") { break }
                commands.insert(command)
            }
        }
        return commands
    }

    // MARK: - State that must survive a crash

    /// Flag files, so a watchdog shell (and the next launch) know what to undo.
    private static let stateFolder: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DoubleShot", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()
    private static let sleepFlag = stateFolder.appendingPathComponent("sleep-disabled")
    private static let lowPowerFlag = stateFolder.appendingPathComponent("low-power-forced")
    private static let inBagFlag = stateFolder.appendingPathComponent("held-in-bag")

    static var sleepDisabledByUs: Bool {
        get { FileManager.default.fileExists(atPath: sleepFlag.path) }
        set { setFlag(sleepFlag, newValue) }
    }

    static var lowPowerForcedByUs: Bool {
        get { FileManager.default.fileExists(atPath: lowPowerFlag.path) }
        set { setFlag(lowPowerFlag, newValue) }
    }

    /// Held awake with the lid shut and no display: if we die now, the watchdog puts the Mac to sleep.
    static var heldInBag: Bool {
        get { FileManager.default.fileExists(atPath: inBagFlag.path) }
        set { if newValue != heldInBag { setFlag(inBagFlag, newValue) } }
    }

    private static func setFlag(_ url: URL, _ on: Bool) {
        if on {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - pmset

    @discardableResult
    static func setSleepDisabled(_ disabled: Bool) -> Bool {
        // Flag and watchdog go first, so a kill right after pmset still gets undone
        if disabled {
            sleepDisabledByUs = true
            startWatchdog()
        }
        let result = Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"])
        Log.lid.notice("disablesleep \(disabled ? 1 : 0) exited with \(result.status)")
        guard result.status == 0 else {
            if disabled {
                sleepDisabledByUs = false
                stopWatchdog()
            }
            return false
        }
        if !disabled {
            sleepDisabledByUs = false
            heldInBag = false
            stopWatchdog()
        }
        return true
    }

    /// Only the battery profile is touched, so the user's own settings for power adapter stay as they are.
    @discardableResult
    static func setLowPowerMode(_ enabled: Bool) -> Bool {
        let result = Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-b", "lowpowermode", enabled ? "1" : "0"])
        Log.lid.notice("lowpowermode \(enabled ? 1 : 0) exited with \(result.status)")
        guard result.status == 0 else { return false }
        lowPowerForcedByUs = enabled
        enabled ? startWatchdog() : stopWatchdog()
        return true
    }

    /// Undo whatever an earlier run left behind, for example after a crash.
    static func cleanUpLeftovers() {
        if sleepDisabledByUs, setSleepDisabled(false) { Log.lid.notice("Cleaned up sleep left disabled by an earlier run") }
        if lowPowerForcedByUs { setLowPowerMode(false) }
    }

    // MARK: - Watchdog

    /// A tiny shell that outlives us. If Double Shot is killed (Force Quit, crash, kill -9) it turns
    /// sleep back on, so a Mac is never left unable to sleep.
    private static var watchdog: Process?

    private static func startWatchdog() {
        guard watchdog?.isRunning != true else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 2; done
        if [ -f "$1" ]; then /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 && /bin/rm -f "$1"; fi
        if [ -f "$2" ]; then /usr/bin/sudo -n /usr/bin/pmset -b lowpowermode 0 && /bin/rm -f "$2"; fi
        if [ -f "$3" ]; then /bin/rm -f "$3"; if /usr/sbin/ioreg -r -k AppleClamshellState -d 1 | /usr/bin/grep -q '"AppleClamshellState" = Yes'; then /usr/bin/pmset sleepnow; fi; fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "doubleshot-watchdog", sleepFlag.path, lowPowerFlag.path, inBagFlag.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            watchdog = process
        } catch {
            Log.lid.error("Could not start the watchdog: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func stopWatchdog() {
        // Still needed while either change is in place
        guard !sleepDisabledByUs, !lowPowerForcedByUs else { return }
        watchdog?.terminate()
        watchdog = nil
    }

    // MARK: - Setup

    enum SetupResult: Equatable {
        case done, cancelled
        case failed(String)
    }

    /// Asks for the admin password once (macOS dialog) and installs the rule.
    static func install() -> SetupResult {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            return .failed("Your account name has characters a sudo rule can't use.")
        }
        let rule = "\(user) ALL=(root) NOPASSWD: " + allowedCommands.joined(separator: ", ")
        // visudo checks the rule before it goes live, a broken sudoers file would lock sudo out
        let script = """
        set -e; TMP=$(/usr/bin/mktemp); trap '/bin/rm -f "$TMP"' EXIT; \
        printf '%s\\n' '\(rule)' > "$TMP"; /usr/sbin/visudo -cf "$TMP"; \
        /bin/mkdir -p -m 0755 /private/etc/sudoers.d; \
        /usr/bin/install -m 0440 -o root -g wheel "$TMP" \(ruleFile); /usr/sbin/visudo -c
        """
        let result = runAsAdmin(script, prompt: "Double Shot needs your password once to keep your Mac awake with the lid closed.")
        guard result == .done else { return result }
        guard isSetUp else {
            return .failed("The rule was added but sudo doesn't read /etc/sudoers.d on this Mac. Check that /etc/sudoers includes it.")
        }
        return .done
    }

    static func uninstall() -> SetupResult {
        // Only undo what we changed, someone may have set disablesleep on purpose
        var script = sleepDisabledByUs ? "/usr/bin/pmset -a disablesleep 0; " : ""
        if lowPowerForcedByUs { script += "/usr/bin/pmset -b lowpowermode 0; " }
        script += "/bin/rm -f \(ruleFile)"
        let result = runAsAdmin(script, prompt: "Double Shot needs your password to remove its lid closed permission.")
        if result == .done {
            sleepDisabledByUs = false
            lowPowerForcedByUs = false
            heldInBag = false
            stopWatchdog()
        }
        return result
    }

    private static func runAsAdmin(_ shell: String, prompt: String) -> SetupResult {
        let escaped = { (text: String) in
            text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let source = "do shell script \"\(escaped(shell))\" with prompt \"\(escaped(prompt))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return .done }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
        Log.lid.error("Admin script failed: \(error, privacy: .public)")
        return .failed("macOS didn't accept the change. Your account needs to be an admin.")
    }
}
