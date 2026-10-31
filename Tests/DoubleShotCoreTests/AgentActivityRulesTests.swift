import DoubleShotCore
import Foundation
import XCTest

final class AgentActivityRulesTests: XCTestCase {
    func testIdleShellHostIsNotActive() {
        // Cursor's waiting zsh: no child, no CPU
        XCTAssertFalse(AgentActivityRules.toolShellIsActive(
            shellCPUSeconds: 0,
            elapsed: 2,
            busyCPUShare: 0.10,
            hasNonShellChild: false
        ))
    }

    func testShellWithToolChildIsActive() {
        XCTAssertTrue(AgentActivityRules.toolShellIsActive(
            shellCPUSeconds: 0,
            elapsed: 2,
            busyCPUShare: 0.10,
            hasNonShellChild: true
        ))
    }

    func testShellWithCPUIsActive() {
        XCTAssertTrue(AgentActivityRules.toolShellIsActive(
            shellCPUSeconds: 0.3,
            elapsed: 2,
            busyCPUShare: 0.10,
            hasNonShellChild: false
        ))
    }

    func testWorkingRequiresASignal() {
        XCTAssertFalse(AgentActivityRules.isWorking(busy: false, latched: false, wroteLogs: false, backgroundRuns: 0))
        XCTAssertTrue(AgentActivityRules.isWorking(busy: true, latched: false, wroteLogs: false, backgroundRuns: 0))
        XCTAssertTrue(AgentActivityRules.isWorking(busy: false, latched: true, wroteLogs: false, backgroundRuns: 0))
        XCTAssertTrue(AgentActivityRules.isWorking(busy: false, latched: false, wroteLogs: true, backgroundRuns: 0))
        XCTAssertTrue(AgentActivityRules.isWorking(busy: false, latched: false, wroteLogs: false, backgroundRuns: 1))
    }

    func testLatchBridgesGapsThenExpires() {
        let now = Date()
        XCTAssertFalse(AgentActivityRules.isLatched(lastBusyAt: nil, now: now, latch: 150))
        XCTAssertTrue(AgentActivityRules.isLatched(lastBusyAt: now.addingTimeInterval(-60), now: now, latch: 150))
        XCTAssertFalse(AgentActivityRules.isLatched(lastBusyAt: now.addingTimeInterval(-200), now: now, latch: 150))
        // latch disabled (tests / --latch=0)
        XCTAssertFalse(AgentActivityRules.isLatched(lastBusyAt: now, now: now, latch: 0))
    }

    func testTurnEndedTranscriptDoesNotCountAsActivity() {
        let path = "/Users/me/.cursor/projects/foo/agent-transcripts/id/id.jsonl"
        XCTAssertFalse(AgentActivityRules.shouldCountLogWrite(
            path: path,
            lastLine: #"{"type":"turn_ended","status":"success"}"#
        ))
        XCTAssertFalse(AgentActivityRules.shouldCountLogWrite(
            path: path,
            lastLine: #"{"type": "turn_ended", "status": "error"}"#
        ))
        XCTAssertFalse(AgentActivityRules.shouldCountLogWrite(path: path, lastLine: nil))
        XCTAssertFalse(AgentActivityRules.shouldCountLogWrite(path: path, lastLine: ""))
    }

    func testInProgressTranscriptLineCountsAsActivity() {
        let path = "/Users/me/.cursor/projects/foo/agent-transcripts/id/id.jsonl"
        XCTAssertTrue(AgentActivityRules.shouldCountLogWrite(
            path: path,
            lastLine: #"{"role":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}"#
        ))
    }

    func testNonTranscriptLogsStillCount() {
        XCTAssertTrue(AgentActivityRules.shouldCountLogWrite(
            path: "/Users/me/.claude/projects/x/session.jsonl",
            lastLine: #"{"type":"turn_ended"}"#
        ))
        XCTAssertTrue(AgentActivityRules.shouldCountLogWrite(
            path: "/Users/me/.cursor/chats/session.db",
            lastLine: nil
        ))
    }

    func testLastNonEmptyLineReadsTail() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("t.jsonl")
        let body = (1...50).map { #"{"n":\#($0)}"# }.joined(separator: "\n")
            + "\n{\"type\":\"turn_ended\",\"status\":\"success\"}\n"
        try body.write(to: file, atomically: true, encoding: .utf8)
        let last = AgentActivityRules.lastNonEmptyLine(of: file.path)
        XCTAssertEqual(last, #"{"type":"turn_ended","status":"success"}"#)
        XCTAssertTrue(AgentActivityRules.isTurnEndedLine(last!))
    }

    func testCursorIDETitleMarker() {
        XCTAssertTrue(AgentActivityRules.matchesCursorIDETitle(
            "Cursor Helper (Plugin): extension-host (agent-exec) double-shot [6-38]"
        ))
        XCTAssertFalse(AgentActivityRules.matchesCursorIDETitle(
            "Cursor Helper (Plugin): extension-host (user) double-shot [6-35]"
        ))
    }

    /// The bug we hit in production: agent stopped, idle zsh left behind, transcript flushed
    /// `turn_ended` — status stayed working. With latch off it must be idle.
    func testStoppedAgentIsIdleDespiteIdleShellAndTurnEndedFlush() {
        XCTAssertFalse(AgentActivityRules.cursorIDEWorkingAfterStop(
            idleShellHostPresent: true,
            transcriptLastLine: #"{"type":"turn_ended","status":"success"}"#,
            latchRemaining: false
        ))
    }

    func testStoppedAgentStaysWorkingOnlyWhileLatched() {
        XCTAssertTrue(AgentActivityRules.cursorIDEWorkingAfterStop(
            idleShellHostPresent: true,
            transcriptLastLine: #"{"type":"turn_ended","status":"success"}"#,
            latchRemaining: true
        ))
    }
}
