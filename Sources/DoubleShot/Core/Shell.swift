import Foundation

enum Shell {
    /// Runs a command and waits for it. Returns the exit status and stdout.
    ///
    /// Waits on a semaphore, not `waitUntilExit()`: that one spins the run loop, so timers
    /// could fire in the middle of a state change and run the same command twice.
    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        let done = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Starts a command without waiting for it.
    static func launch(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
