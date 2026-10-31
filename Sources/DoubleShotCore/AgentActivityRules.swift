import Foundation

/// Pure rules for “is this agent working?” — unit-tested without process tables or the UI.
public enum AgentActivityRules: Sendable {
    public static let defaultWorkingLatch: TimeInterval = 2.5 * 60
    public static let shellNames: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "nu"]

    /// Cursor IDE keeps an idle zsh host under agent-exec between commands. Count a shell as a
    /// tool call only when it has a real child or is itself using meaningful CPU.
    public static func toolShellIsActive(
        shellCPUSeconds: Double,
        elapsed: TimeInterval,
        busyCPUShare: Double,
        hasNonShellChild: Bool
    ) -> Bool {
        let elapsed = max(elapsed, 0.001)
        return hasNonShellChild
            || shellCPUSeconds / elapsed >= busyCPUShare
            || shellCPUSeconds > 0.05
    }

    /// Whether a session should show as working from the usual signals.
    public static func isWorking(
        busy: Bool,
        latched: Bool,
        wroteLogs: Bool,
        backgroundRuns: Int
    ) -> Bool {
        busy || latched || wroteLogs || backgroundRuns > 0
    }

    public static func isLatched(lastBusyAt: Date?, now: Date, latch: TimeInterval) -> Bool {
        guard latch > 0, let lastBusyAt else { return false }
        return now.timeIntervalSince(lastBusyAt) < latch
    }

    /// Cursor `agent-transcripts` are often flushed at turn boundaries, including `turn_ended`.
    /// Counting those mtimes keeps status “working” after the user already stopped the agent.
    public static func shouldCountLogWrite(path: String, lastLine: String?) -> Bool {
        guard path.contains("/agent-transcripts/") else { return true }
        guard let lastLine, !lastLine.isEmpty else { return false }
        return !isTurnEndedLine(lastLine)
    }

    public static func isTurnEndedLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // Transcript lines are compact JSON; accept either spacing style.
        return trimmed.contains("\"type\":\"turn_ended\"")
            || trimmed.contains("\"type\": \"turn_ended\"")
    }

    /// Last non-empty line of a file (reads a tail window — enough for jsonl events).
    public static func lastNonEmptyLine(of path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        guard size > 0 else { return nil }
        let window = min(size, 32_768)
        handle.seek(toFileOffset: size - window)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: \.isNewline)
            .map(String.init)
            .last { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public static func matchesCursorIDETitle(_ argument: String) -> Bool {
        argument.contains("extension-host (agent-exec)")
    }

    /// End-to-end Cursor IDE decision used by tests: after the user stops an agent, an idle
    /// shell host plus a `turn_ended` transcript flush must not keep status working when latch is off.
    public static func cursorIDEWorkingAfterStop(
        idleShellHostPresent: Bool,
        transcriptLastLine: String?,
        latchRemaining: Bool
    ) -> Bool {
        let shellBusy = toolShellIsActive(
            shellCPUSeconds: 0,
            elapsed: 2,
            busyCPUShare: 0.10,
            hasNonShellChild: false
        )
        // idleShellHostPresent is intentional noise — must not matter
        _ = idleShellHostPresent
        let wrote = shouldCountLogWrite(
            path: "/Users/x/.cursor/projects/p/agent-transcripts/id/id.jsonl",
            lastLine: transcriptLastLine
        )
        return isWorking(busy: shellBusy, latched: latchRemaining, wroteLogs: wrote, backgroundRuns: 0)
    }
}
