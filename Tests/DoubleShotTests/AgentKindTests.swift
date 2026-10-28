import Testing
@testable import DoubleShot

/// A process as AgentMonitor sees it, and what Double Shot should make of it.
struct AgentRun: Sendable, CustomTestStringConvertible {
    /// Process name (`pbi_name`).
    var name: String
    /// Binary path, only looked up for native binaries.
    var path: String?
    var argv: [String]
    /// The agent it is, nil when it isn't one.
    var agent: String?
    var background = false
    var service = false

    var testDescription: String { "\(name): \(argv.joined(separator: " "))" }
}

private let home = "/Users/me"
private let claudeScript = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
private let geminiScript = "/opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js"
private let cursorVersion = "\(home)/.local/share/cursor-agent/versions/2025.10.1"

private let runs: [AgentRun] = [
    // Native Claude Code
    AgentRun(name: "claude", path: "\(home)/.local/bin/claude", argv: ["claude"], agent: "claude"),
    AgentRun(name: "claude", path: "\(home)/.local/bin/claude", argv: ["claude", "--resume"], agent: "claude"),
    AgentRun(name: "claude", path: "\(home)/.local/bin/claude", argv: ["claude", "-p", "fix the failing test"],
             agent: "claude", background: true),
    AgentRun(name: "claude", path: "\(home)/.local/bin/claude", argv: ["claude", "--model", "opus", "--print", "summarize"],
             agent: "claude", background: true),
    // A folder named like the agent is an argument, not a script
    AgentRun(name: "claude", path: "\(home)/.local/bin/claude",
             argv: ["claude", "--add-dir", "\(home)/src/claude", "-p", "hello"], agent: "claude", background: true),
    AgentRun(name: "claude", path: "\(home)/.local/bin/claude",
             argv: ["claude", "-p", "hello", "--add-dir", "\(home)/claude"], agent: "claude", background: true),
    // Desktop apps and IDEs drive their sessions over stream-json, whatever the flags
    AgentRun(name: "claude", path: "\(home)/.local/bin/claude",
             argv: ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json"], agent: "claude"),
    AgentRun(name: "claude", path: "\(home)/.local/bin/claude", argv: ["claude", "-p", "--input-format=stream-json"],
             agent: "claude"),
    AgentRun(name: "claude", path: "\(home)/.local/bin/claude", argv: ["claude", "mcp", "serve"], agent: "claude", service: true),
    AgentRun(name: "claude", path: "\(home)/.local/bin/claude", argv: ["claude", "--chrome-native-host"],
             agent: "claude", service: true),
    // An empty argument is kept by the parser and doesn't hide what follows
    AgentRun(name: "claude", path: "\(home)/.local/bin/claude", argv: ["claude", "--append-system-prompt", "", "-p", "hi"],
             agent: "claude", background: true),

    // Claude's native installer names the binary after its version
    AgentRun(name: "2.1.3", path: "\(home)/.local/share/claude/versions/2.1.3", argv: ["claude"], agent: "claude"),
    AgentRun(name: "2.1.3", path: "\(home)/.local/share/claude/versions/2.1.3", argv: ["claude", "--print", "hi"],
             agent: "claude", background: true),

    // Claude Code from npm, and node that renamed its process to the agent
    AgentRun(name: "node", argv: ["node", claudeScript], agent: "claude"),
    AgentRun(name: "node", argv: ["node", "--max-old-space-size=8192", claudeScript, "-p", "hi"], agent: "claude", background: true),
    AgentRun(name: "node", argv: ["node", claudeScript, "--add-dir", "\(home)/src/claude", "-p", "hi"],
             agent: "claude", background: true),
    AgentRun(name: "node", argv: ["claude", "", "", ""], agent: "claude"),

    // Codex, native and from npm
    AgentRun(name: "codex", path: "/opt/homebrew/bin/codex", argv: ["codex"], agent: "codex"),
    AgentRun(name: "codex", path: "/opt/homebrew/bin/codex", argv: ["codex", "exec", "fix it"], agent: "codex", background: true),
    AgentRun(name: "codex", path: "/opt/homebrew/bin/codex", argv: ["codex", "-m", "o3", "exec", "fix it"],
             agent: "codex", background: true),
    AgentRun(name: "codex", path: "/opt/homebrew/bin/codex", argv: ["codex", "mcp-server"], agent: "codex", service: true),
    AgentRun(name: "node", argv: ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js", "exec", "fix it"],
             agent: "codex", background: true),
    // A launcher Double Shot doesn't know by name still has its script skipped
    AgentRun(name: "node", argv: ["nodejs", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js", "mcp-server"],
             agent: "codex", service: true),

    // Gemini CLI under node and bun
    AgentRun(name: "node", argv: ["node", geminiScript], agent: "gemini"),
    AgentRun(name: "node", argv: ["node", geminiScript, "-p", "explain this"], agent: "gemini", background: true),
    AgentRun(name: "bun", argv: ["bun", "run", "\(home)/.bun/install/global/node_modules/@google/gemini-cli/dist/index.js",
                                 "--prompt", "hi"], agent: "gemini", background: true),

    // Cursor Agent runs as its own bundled node
    AgentRun(name: "node", argv: ["\(cursorVersion)/node", "\(cursorVersion)/index.js"], agent: "cursor"),
    AgentRun(name: "node", argv: ["\(cursorVersion)/node", "\(cursorVersion)/index.js", "-p", "hi"],
             agent: "cursor", background: true),

    // Aider under python
    AgentRun(name: "python3.12", argv: ["/opt/homebrew/bin/python3.12", "\(home)/.local/bin/aider", "--message", "fix"],
             agent: "aider", background: true),
    AgentRun(name: "Python", argv: ["/Library/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python",
                                    "-m", "aider"], agent: "aider"),

    // Not agents
    AgentRun(name: "node", argv: ["node", "\(home)/app/server.js"]),
    AgentRun(name: "python3", argv: ["python3", "-m", "http.server"]),
    AgentRun(name: "zsh", path: "/bin/zsh", argv: ["-zsh"]),
]

@Suite struct AgentKindTests {
    @Test(arguments: runs)
    func classifiesTheRun(_ run: AgentRun) throws {
        // AgentMonitor looks up the path of native binaries and the arguments of interpreters
        let isInterpreter = AgentKind.isInterpreter(run.name)
        let matched = AgentKind.all.filter {
            $0.matches(name: run.name, path: isInterpreter ? nil : run.path, arguments: isInterpreter ? run.argv : nil)
        }
        #expect(matched.map(\.id) == (run.agent.map { [$0] } ?? []))
        guard let kind = matched.first else { return }
        #expect(kind.isBackgroundRun(run.argv) == run.background, "background run")
        #expect(kind.isService(run.argv) == run.service, "service")
    }
}
