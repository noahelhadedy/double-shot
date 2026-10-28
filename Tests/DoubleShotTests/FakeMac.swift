import Foundation
@testable import DoubleShot

/// A Mac for AwakeEngine to run against. The test sets its readings; pmset and the power
/// assertions only change this object. It keeps LidHold's flag files the way LidHold does, so the
/// engine sees what it would see on a real Mac, and no test needs a password or changes how this
/// Mac sleeps.
@MainActor
final class FakeMac: PowerSystem {
    // Readings the test sets
    var thermal: ProcessInfo.ThermalState = .nominal
    var battery: SystemState.Battery? = SystemState.Battery(percent: 80, isOnBattery: true)
    var isClosedInBag = false
    var isLidSetUp = true
    /// pmset commands that fail, like "disablesleep 0".
    var failing: Set<String> = []

    // What pmset has set
    private(set) var sleepDisabled = false
    /// `pmset -b lowpowermode`: the battery profile, so it's only in effect on battery.
    private(set) var batteryLowPowerMode = false
    var isLowPowerModeOn: Bool { batteryLowPowerMode && battery?.isOnBattery == true }

    // LidHold's flag files
    private(set) var sleepDisabledByUs = false
    private(set) var lowPowerForcedByUs = false
    var heldInBag = false

    // What the engine did
    private(set) var pmsetCalls: [String] = []
    private(set) var keepAwake = false
    private(set) var keepDisplayOn = false
    private(set) var displaySleeps = 0
    /// `pmset sleepnow` calls that put the Mac to sleep. While sleep is disabled they do nothing.
    private(set) var sleeps = 0

    func setSleepDisabled(_ disabled: Bool) -> Bool {
        guard pmset("disablesleep \(disabled ? 1 : 0)") else {
            // LidHold sets its flag before turning sleep off, and takes it back when that fails
            if disabled { sleepDisabledByUs = false }
            return false
        }
        sleepDisabled = disabled
        sleepDisabledByUs = disabled
        if !disabled { heldInBag = false }
        return true
    }

    @discardableResult
    func setLowPowerMode(_ enabled: Bool) -> Bool {
        guard pmset("lowpowermode \(enabled ? 1 : 0)") else { return false }
        batteryLowPowerMode = enabled
        lowPowerForcedByUs = enabled
        return true
    }

    func cleanUpLeftovers() {
        if sleepDisabledByUs { _ = setSleepDisabled(false) }
        if lowPowerForcedByUs { setLowPowerMode(false) }
    }

    func setAssertions(keepAwake: Bool, keepDisplayOn: Bool) {
        self.keepAwake = keepAwake
        self.keepDisplayOn = keepDisplayOn
    }

    func sleepNow() {
        if !sleepDisabled { sleeps += 1 }
    }

    func displaySleepNow() {
        displaySleeps += 1
    }

    func calls(_ command: String) -> Int {
        pmsetCalls.filter { $0 == command }.count
    }

    private func pmset(_ command: String) -> Bool {
        pmsetCalls.append(command)
        return !failing.contains(command)
    }
}

/// An engine on a FakeMac, with its own settings and a clock the test moves. The engine is never
/// started, so no agent watching, update check or tick runs and a settings change doesn't check
/// again by itself; tests call `wait`. turnOn still schedules its end timer, but nothing waits for it.
@MainActor
final class EngineHarness {
    let mac = FakeMac()
    let prefs: Preferences
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let suiteName = "DoubleShotTests.\(UUID().uuidString)"
    private let defaults: UserDefaults
    private(set) lazy var engine = AwakeEngine(prefs: prefs, system: mac, now: { [unowned self] in self.now })

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        prefs = Preferences(defaults: defaults)
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    /// Time passes and the engine checks again, as its timer does every few seconds.
    func wait(_ seconds: TimeInterval) {
        now += seconds
        engine.update()
    }

    /// What AgentMonitor reports after a check: Claude Code working or idle.
    func agents(working: Bool) {
        let claude = AgentKind.all.first { $0.id == "claude" }!
        engine.agents.publish([AgentMonitor.Status(kind: claude, sessions: 1, backgroundRuns: 0, isWorking: working)], at: now)
        engine.update()
    }
}
