import AppKit
import IOKit
import IOKit.ps

/// Reads what the Mac is doing right now: lid, displays, battery, heat.
enum SystemState {
    /// True when the built-in display's lid is shut.
    static var isLidClosed: Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(rootDomain) }
        let value = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? Bool) ?? false
    }

    /// Any non built-in display that's connected. A monitor in display sleep still counts:
    /// it's a desk setup with a dark screen, not a Mac in a bag.
    static var hasExternalDisplay: Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    /// Lid shut with no external display: the Mac is probably in a bag, not on a desk.
    static var isClosedInBag: Bool {
        isLidClosed && !hasExternalDisplay
    }

    /// Whether this Mac has a lid at all (MacBooks report a clamshell state, desktops don't).
    static var hasLid: Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(rootDomain) }
        return IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0) != nil
    }

    struct Battery {
        var percent: Int
        var isOnBattery: Bool
    }

    /// nil on Macs without a battery.
    static var battery: Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let state = description[kIOPSPowerSourceStateKey] as? String
            return Battery(percent: current * 100 / max, isOnBattery: state == kIOPSBatteryPowerValue)
        }
        return nil
    }

    static var thermal: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }

    static var isLowPowerModeOn: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    static func sleepNow() {
        Log.power.notice("Putting the Mac to sleep")
        Shell.launch("/usr/bin/pmset", ["sleepnow"])
    }

    static func displaySleepNow() {
        Shell.launch("/usr/bin/pmset", ["displaysleepnow"])
    }
}
