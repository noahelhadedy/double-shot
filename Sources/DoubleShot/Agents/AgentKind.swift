import Foundation

/// A coding agent Double Shot knows how to spot.
struct AgentKind: Hashable, Sendable {
    let id: String
    let name: String
    /// Binary names, matched exactly against the process name or the last path component.
    let executables: Set<String>
    /// Install folders for agents that run inside node, bun or python, matched in the script path.
    var packages: [String] = []
    /// Folders whose binaries are named after a version (Claude's native installer: .../claude/versions/2.1.3).
    var versionFolders: [String] = []
    /// Folders (relative to home) the agent writes its session logs to while it works.
    var logFolders: [String] = []
    /// Flags that start a one-shot, non-interactive run (`claude -p`), anywhere in the arguments.
    var backgroundFlags: Set<String> = []
    /// Subcommands that start a one-shot run (`codex exec`).
    var backgroundCommands: Set<String> = []
    /// Runs that aren't a coding session at all (the Chrome bridge, `claude mcp serve`).
    var serviceFlags: Set<String> = []
    var serviceCommands: Set<String> = []

    static let all: [AgentKind] = [
        AgentKind(id: "claude", name: "Claude Code", executables: ["claude"],
                  packages: ["/node_modules/@anthropic-ai/claude-code/"],
                  versionFolders: ["/claude/versions/"],
                  logFolders: [".claude/projects"],
                  backgroundFlags: ["-p", "--print"],
                  serviceFlags: ["--chrome-native-host"],
                  serviceCommands: ["mcp"]),
        AgentKind(id: "codex", name: "Codex", executables: ["codex"],
                  packages: ["/node_modules/@openai/codex/"],
                  logFolders: [".codex/sessions"],
                  backgroundCommands: ["exec", "e"],
                  serviceCommands: ["mcp", "mcp-server"]),
        AgentKind(id: "gemini", name: "Gemini CLI", executables: ["gemini"],
                  packages: ["/node_modules/@google/gemini-cli/"],
                  logFolders: [".gemini/tmp"],
                  backgroundFlags: ["-p", "--prompt"]),
        AgentKind(id: "cursor", name: "Cursor Agent", executables: ["cursor-agent"],
                  versionFolders: ["/cursor-agent/versions/"],
                  logFolders: [".cursor/chats"],
                  backgroundFlags: ["-p", "--print"]),
        AgentKind(id: "copilot", name: "Copilot CLI", executables: ["copilot"],
                  packages: ["/node_modules/@github/copilot/"],
                  logFolders: [".copilot/session-state"],
                  backgroundFlags: ["-p", "--prompt"]),
        AgentKind(id: "opencode", name: "OpenCode", executables: ["opencode"],
                  packages: ["/node_modules/opencode-ai/"],
                  logFolders: [".local/share/opencode"],
                  backgroundCommands: ["run"]),
        AgentKind(id: "amp", name: "Amp", executables: ["amp"],
                  packages: ["/node_modules/@sourcegraph/amp/"],
                  backgroundFlags: ["-x", "--execute"]),
        AgentKind(id: "aider", name: "Aider", executables: ["aider"],
                  backgroundFlags: ["-m", "--message", "--message-file"]),
    ]

    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "Python"]

    static func isInterpreter(_ executable: String) -> Bool {
        interpreters.contains(executable) || executable.hasPrefix("python")
    }

    /// `name` is the process name, `path` its binary, `arguments` its argv (needed for interpreters).
    func matches(name: String, path: String?, arguments: [String]?) -> Bool {
        if executables.contains(name) { return true }
        if let path {
            if executables.contains((path as NSString).lastPathComponent) { return true }
            if versionFolders.contains(where: { path.contains($0) }) { return true }
        }
        guard AgentKind.isInterpreter(name), let arguments else { return false }
        // argv[0] too: a node CLI that sets process.title shows up as just "claude".
        // A few arguments in: covers `node --flag script`, `bun run script` and `python -m aider`
        return arguments.prefix(5).contains(where: isAgentArgument)
    }

    private func isAgentArgument(_ argument: String) -> Bool {
        executables.contains((argument as NSString).lastPathComponent)
            || packages.contains { argument.contains($0) }
    }

    /// The agent's own arguments: what comes after the script (`node cli.js`, `python -m aider`),
    /// or after the binary itself.
    private func ownArguments(_ arguments: [String]) -> [String] {
        let rest = arguments.dropFirst()
        guard let script = rest.prefix(4).firstIndex(where: isAgentArgument) else { return Array(rest) }
        return Array(rest[(script + 1)...])
    }

    /// A one-shot run works until it exits. The desktop apps talk to their sessions over
    /// stream-json, which makes them interactive whatever flags they carry.
    func isBackgroundRun(_ arguments: [String]) -> Bool {
        let own = ownArguments(arguments)
        if own.contains("--input-format=stream-json") { return false }
        if let index = own.firstIndex(of: "--input-format"), own.indices.contains(index + 1),
           own[index + 1] == "stream-json" {
            return false
        }
        if own.contains(where: { backgroundFlags.contains($0) }) { return true }
        // Subcommands can come after options with values (`codex -m o3 exec`)
        return own.contains(where: backgroundCommands.contains)
    }

    /// Not a coding session: a bridge or server the agent's binary also provides.
    func isService(_ arguments: [String]) -> Bool {
        let own = ownArguments(arguments)
        if own.contains(where: serviceFlags.contains) { return true }
        guard let command = own.first(where: { !$0.hasPrefix("-") }) else { return false }
        return serviceCommands.contains(command)
    }
}
