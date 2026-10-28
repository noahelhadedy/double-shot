import Foundation
import IOKit.pwr_mgt

/// Everything AwakeEngine reads from the Mac and changes on it. `LivePowerSystem` is the real Mac;
/// tests pass a fake, so they never need a password, run pmset or hold a power assertion.
@MainActor
protocol PowerSystem: AnyObject {
    var thermal: ProcessInfo.ThermalState { get }
    var battery: SystemState.Battery? { get }
    var isClosedInBag: Bool { get }
    var isLowPowerModeOn: Bool { get }

    // The lid hold, see LidHold
    var isLidSetUp: Bool { get }
    var sleepDisabledByUs: Bool { get }
    var lowPowerForcedByUs: Bool { get }
    var heldInBag: Bool { get set }
    func setSleepDisabled(_ disabled: Bool) -> Bool
    @discardableResult func setLowPowerMode(_ enabled: Bool) -> Bool
    func cleanUpLeftovers()

    /// The two idle sleep assertions: the Mac's and the display's.
    func setAssertions(keepAwake: Bool, keepDisplayOn: Bool)
    func sleepNow()
    func displaySleepNow()
}

@MainActor
final class LivePowerSystem: PowerSystem {
    private let systemAssertion = PowerAssertion(type: kIOPMAssertionTypePreventUserIdleSystemSleep, reason: "Double Shot is keeping your Mac awake")
    private let displayAssertion = PowerAssertion(type: kIOPMAssertionTypePreventUserIdleDisplaySleep, reason: "Double Shot is keeping your display on")

    var thermal: ProcessInfo.ThermalState { SystemState.thermal }
    var battery: SystemState.Battery? { SystemState.battery }
    var isClosedInBag: Bool { SystemState.isClosedInBag }
    var isLowPowerModeOn: Bool { SystemState.isLowPowerModeOn }

    var isLidSetUp: Bool { LidHold.isSetUp }
    var sleepDisabledByUs: Bool { LidHold.sleepDisabledByUs }
    var lowPowerForcedByUs: Bool { LidHold.lowPowerForcedByUs }
    var heldInBag: Bool {
        get { LidHold.heldInBag }
        set { LidHold.heldInBag = newValue }
    }
    func setSleepDisabled(_ disabled: Bool) -> Bool { LidHold.setSleepDisabled(disabled) }
    @discardableResult func setLowPowerMode(_ enabled: Bool) -> Bool { LidHold.setLowPowerMode(enabled) }
    func cleanUpLeftovers() { LidHold.cleanUpLeftovers() }

    func setAssertions(keepAwake: Bool, keepDisplayOn: Bool) {
        systemAssertion.set(keepAwake)
        displayAssertion.set(keepDisplayOn)
    }
    func sleepNow() { SystemState.sleepNow() }
    func displaySleepNow() { SystemState.displaySleepNow() }
}
