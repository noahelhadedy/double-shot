import Foundation
import Testing
@testable import DoubleShot

/// A KERN_PROCARGS2 buffer: argc as a native Int32, then the bytes as written ("\0" for each NUL).
private func procargs(argc: Int32, _ bytes: String) -> [UInt8] {
    withUnsafeBytes(of: argc) { Array($0) } + Array(bytes.utf8)
}

@Suite struct ProcessArgumentTests {
    @Test func readsEveryArgumentAndStopsBeforeTheEnvironment() {
        let buffer = procargs(argc: 3, "/usr/local/bin/claude\0\0\0\0claude\0-p\0hello\0PATH=/usr/bin\0\0")
        #expect(ProcessTable.parseArguments(buffer) == ["claude", "-p", "hello"])
    }

    /// Captured from `/bin/sh -c 'sleep 30; :' '' -p hello` on macOS: the empty argument is one extra NUL.
    @Test func keepsAnEmptyArgumentAndWhatFollowsIt() {
        let buffer = procargs(argc: 6, "/bin/bash\0\0\0\0\0\0\0/bin/sh\0-c\0sleep 30; :\0\0-p\0hello\0")
        #expect(ProcessTable.parseArguments(buffer) == ["/bin/sh", "-c", "sleep 30; :", "", "-p", "hello"])
    }

    @Test func keepsEmptyArgumentsAtTheEnd() {
        let buffer = procargs(argc: 6, "/bin/bash\0\0\0\0\0\0\0/bin/sh\0-c\0sleep 30; :\0x\0\0\0")
        #expect(ProcessTable.parseArguments(buffer) == ["/bin/sh", "-c", "sleep 30; :", "x", "", ""])
    }

    /// Captured from node after `process.title = "claude"`: the old arguments are all NULs, then
    /// the environment starts.
    @Test func aRewrittenTitleNeverReadsTheEnvironmentAsArguments() throws {
        let zeroedArguments = String(repeating: "\0", count: 40)
        let buffer = procargs(argc: 7, "/opt/homebrew/bin/node\0\0claude\0\(zeroedArguments)DS_ENV_MARKER=yes\0\0\0")
        let arguments = try #require(ProcessTable.parseArguments(buffer))
        #expect(arguments.first == "claude")
        #expect(!arguments.contains("DS_ENV_MARKER=yes"))
        #expect(arguments.dropFirst().allSatisfy { $0.isEmpty })
    }

    @Test(arguments: [
        ("empty buffer", [UInt8](), nil),
        ("shorter than argc", [1, 0, 0], nil),
        ("negative argc", procargs(argc: -1, "/bin/sh\0\0sh\0"), nil),
        ("no arguments", procargs(argc: 0, "/bin/sh\0\0\0"), []),
        ("fewer arguments than argc", procargs(argc: 5, "/bin/sh\0\0claude\0-p\0"), ["claude", "-p"]),
        ("last argument cut off", procargs(argc: 3, "/bin/sh\0\0claude\0-p\0hel"), ["claude", "-p", "hel"]),
        ("exec path cut off", procargs(argc: 2, "/usr/local/bi"), []),
    ] as [(String, [UInt8], [String]?)])
    func survivesMalformedBuffers(_ label: String, _ buffer: [UInt8], _ expected: [String]?) {
        #expect(ProcessTable.parseArguments(buffer) == expected, "\(label)")
    }

    /// The real kernel layout, from a live process.
    @Test func readsALiveProcessWithAnEmptyArgument() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        // `read` waits on stdin inside the shell itself, so killing the shell leaves nothing behind
        child.arguments = ["-c", "read line", "", "-p", "hello"]
        child.standardInput = Pipe()
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }
        #expect(ProcessTable.arguments(of: child.processIdentifier) == ["/bin/sh", "-c", "read line", "", "-p", "hello"])
    }
}
