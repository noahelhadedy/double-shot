import Foundation
import Observation

/// Every user setting in one place, backed by UserDefaults.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let keepDisplayOn = "keepDisplayOn"
        static let defaultMinutes = "defaultMinutes"
        static let leftClickToggles = "leftClickToggles"
        static let turnOnAtLaunch = "turnOnAtLaunch"
        static let lidClosed = "lidClosed"
        static let lowPowerWhileClosed = "lowPowerWhileClosed"
        static let agentMode = "agentMode"
        static let agentGraceMinutes = "agentGraceMinutes"
        static let batteryGuard = "batteryGuard"
        static let batteryGuardPercent = "batteryGuardPercent"
        static let heatGuard = "heatGuard"
    }

    private init() {
        defaults.register(defaults: [
            Key.keepDisplayOn: true,
            Key.defaultMinutes: 0,
            Key.leftClickToggles: false,
            Key.turnOnAtLaunch: false,
            Key.lidClosed: true,
            Key.lowPowerWhileClosed: true,
            Key.agentMode: true,
            Key.agentGraceMinutes: 3,
            Key.batteryGuard: true,
            Key.batteryGuardPercent: 20,
            Key.heatGuard: true,
        ])
        keepDisplayOn = defaults.bool(forKey: Key.keepDisplayOn)
        defaultMinutes = defaults.integer(forKey: Key.defaultMinutes)
        leftClickToggles = defaults.bool(forKey: Key.leftClickToggles)
        turnOnAtLaunch = defaults.bool(forKey: Key.turnOnAtLaunch)
        // One lid setting now covers both you and agents; the old agents-only one is folded in
        if defaults.object(forKey: "agentLidClosed") != nil {
            defaults.set(defaults.bool(forKey: Key.lidClosed) || defaults.bool(forKey: "agentLidClosed"), forKey: Key.lidClosed)
            defaults.removeObject(forKey: "agentLidClosed")
        }
        lidClosed = defaults.bool(forKey: Key.lidClosed)
        lowPowerWhileClosed = defaults.bool(forKey: Key.lowPowerWhileClosed)
        agentMode = defaults.bool(forKey: Key.agentMode)
        agentGraceMinutes = defaults.integer(forKey: Key.agentGraceMinutes)
        batteryGuard = defaults.bool(forKey: Key.batteryGuard)
        batteryGuardPercent = defaults.integer(forKey: Key.batteryGuardPercent)
        heatGuard = defaults.bool(forKey: Key.heatGuard)
    }

    /// Fired after any setting changes, so the engine can re-check its state.
    @ObservationIgnored var onChange: (() -> Void)?

    // General
    var keepDisplayOn: Bool { didSet { save(keepDisplayOn, Key.keepDisplayOn) } }
    /// 0 means until turned off.
    var defaultMinutes: Int { didSet { save(defaultMinutes, Key.defaultMinutes) } }
    var leftClickToggles: Bool { didSet { save(leftClickToggles, Key.leftClickToggles) } }
    var turnOnAtLaunch: Bool { didSet { save(turnOnAtLaunch, Key.turnOnAtLaunch) } }

    // Lid closed, for both your own sessions and agents (needs the one-time setup)
    var lidClosed: Bool { didSet { save(lidClosed, Key.lidClosed) } }
    var lowPowerWhileClosed: Bool { didSet { save(lowPowerWhileClosed, Key.lowPowerWhileClosed) } }

    // AI agents
    var agentMode: Bool { didSet { save(agentMode, Key.agentMode) } }
    var agentGraceMinutes: Int { didSet { save(agentGraceMinutes, Key.agentGraceMinutes) } }

    // Safety
    var batteryGuard: Bool { didSet { save(batteryGuard, Key.batteryGuard) } }
    var batteryGuardPercent: Int { didSet { save(batteryGuardPercent, Key.batteryGuardPercent) } }
    var heatGuard: Bool { didSet { save(heatGuard, Key.heatGuard) } }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        onChange?()
    }
}
