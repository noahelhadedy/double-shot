import Darwin
import Foundation

/// A snapshot of every process: name, parent and CPU time used so far.
struct ProcessTable {
    struct Entry {
        let pid: pid_t
        let parent: pid_t
        let name: String
        /// Seconds since 1970 when the process started.
        let startTime: Double
        /// User plus system CPU time in seconds, including children it has already reaped
        /// (short tool calls that ran and exited between two checks).
        let cpuSeconds: Double
    }

    let entries: [pid_t: Entry]
    let children: [pid_t: [pid_t]]

    private static let ticksToSeconds: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()

    static func snapshot() -> ProcessTable {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))

        var entries: [pid_t: Entry] = [:]
        var children: [pid_t: [pid_t]] = [:]
        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }

            let name = withUnsafeBytes(of: info.pbi_name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            let fallback = withUnsafeBytes(of: info.pbi_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }

            var usage = rusage_info_v2()
            let cpu: Double = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { raw in
                    guard proc_pid_rusage(pid, RUSAGE_INFO_V2, raw) == 0 else { return 0 }
                    let usage = pointer.pointee
                    let own = usage.ri_user_time + usage.ri_system_time
                    let children = usage.ri_child_user_time + usage.ri_child_system_time
                    return Double(own + children) * ticksToSeconds
                }
            }

            let parent = pid_t(info.pbi_ppid)
            let start = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
            entries[pid] = Entry(pid: pid, parent: parent, name: name.isEmpty ? fallback : name, startTime: start, cpuSeconds: cpu)
            children[parent, default: []].append(pid)
        }
        return ProcessTable(entries: entries, children: children)
    }

    /// The pid and everything it started, however deep, except branches `skip` rules out.
    func tree(of root: pid_t, skip: (Entry) -> Bool = { _ in false }) -> [pid_t] {
        var result: [pid_t] = []
        var stack = [root]
        while let pid = stack.popLast() {
            result.append(pid)
            for child in children[pid] ?? [] {
                if let entry = entries[child], skip(entry) { continue }
                stack.append(child)
            }
        }
        return result
    }

    /// The full argv of a process, argv[0] included.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        // Layout: argc, exec path, padding zeros, argv[0], argv[1]...
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        func nextString() -> String? {
            while index < size && buffer[index] == 0 { index += 1 }
            guard index < size else { return nil }
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            return String(decoding: buffer[start..<index], as: UTF8.self)
        }
        _ = nextString() // exec path
        var arguments: [String] = []
        for number in 0..<argc {
            // Arguments are split by one zero byte. A run of zeros after argv[0] means the process
            // rewrote its title (node's process.title) and what follows is the environment.
            if number > 0, index + 1 < size, buffer[index] == 0, buffer[index + 1] == 0 { break }
            guard let argument = nextString() else { break }
            arguments.append(argument)
        }
        return arguments
    }
}
