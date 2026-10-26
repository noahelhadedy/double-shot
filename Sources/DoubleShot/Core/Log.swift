import os

/// Read the logs with: /usr/bin/log stream --predicate 'subsystem == "com.noahelhadedy.DoubleShot"'
enum Log {
    private static let subsystem = "com.noahelhadedy.DoubleShot"
    static let engine = Logger(subsystem: subsystem, category: "Engine")
    static let power = Logger(subsystem: subsystem, category: "Power")
    static let lid = Logger(subsystem: subsystem, category: "Lid")
    static let agents = Logger(subsystem: subsystem, category: "Agents")
}
