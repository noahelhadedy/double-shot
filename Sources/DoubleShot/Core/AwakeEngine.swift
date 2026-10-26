import AppKit
import IOKit.pwr_mgt
import Observation

/// Decides whether the Mac stays awake and makes it so.
///
/// Two things can keep it awake: the user (on, for a while or until turned off) and working
/// AI agents. On top of that it can hold the Mac awake with the lid closed, and it lets go
/// on its own when the Mac gets hot or the battery runs low.
@MainActor
@Observable
final class AwakeEngine {
    enum Cutoff: Equatable {
        case heat, battery
    }

    // What the user asked for
    private(set) var isManualOn = false
    private(set) var manualEnd: Date?
    /// The duration picked when it was turned on, 0 for until turned off.
    private(set) var manualMinutes = 0

    // What agents asked for
    private(set) var isHeldForAgents = false
    /// Turned off by hand while agents worked: stay off until they go quiet.
    private(set) var isAgentHoldSuppressed = false

    // What's in effect
    private(set) var isLidHeld = false
    private(set) var lastCutoff: Cutoff?
    private(set) var isLidSetUp = false

    var isAwake: Bool { isManualOn || isHeldForAgents }

    let agents = AgentMonitor()
    let prefs = Preferences.shared

    /// Fired whenever anything visible changed, for the menu bar icon.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let systemAssertion = PowerAssertion(type: kIOPMAssertionTypePreventUserIdleSystemSleep, reason: "Double Shot is keeping your Mac awake")
    @ObservationIgnored private let displayAssertion = PowerAssertion(type: kIOPMAssertionTypePreventUserIdleDisplaySleep, reason: "Double Shot is keeping your display on")
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var endTimer: Timer?
    @ObservationIgnored private var wasInBag = false
    @ObservationIgnored private var isShuttingDown = false
    /// After a failed pmset call, wait before trying again instead of calling sudo every tick.
    @ObservationIgnored private var lidRetryAfter = Date.distantPast

    // MARK: - Life cycle

    func start() {
        isLidSetUp = LidHold.isSetUp
        // A previous run that crashed may have left sleep disabled or Low Power Mode on
        LidHold.cleanUpLeftovers()

        prefs.onChange = { [weak self] in self?.update() }
        agents.onUpdate = { [weak self] in self?.update() }
        if prefs.agentMode { agents.start() }

        tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }

        if prefs.turnOnAtLaunch { turnOn(minutes: prefs.defaultMinutes) }
        update()
    }

    /// Everything back to normal, called on quit. Never puts the Mac to sleep: quitting during a
    /// logout or restart must only undo our changes.
    func shutdown() {
        isShuttingDown = true
        isManualOn = false
        isHeldForAgents = false
        agents.stop()
        apply()
        LidHold.cleanUpLeftovers()
    }

    func refreshLidSetup() {
        isLidSetUp = LidHold.isSetUp
        update()
    }

    // MARK: - User actions

    /// minutes == 0 means until turned off.
    func turnOn(minutes: Int) {
        isManualOn = true
        lastCutoff = nil
        manualMinutes = minutes
        manualEnd = minutes > 0 ? Date().addingTimeInterval(TimeInterval(minutes * 60)) : nil
        scheduleEndTimer()
        Log.engine.notice("Turned on for \(minutes) minutes (0 = until turned off)")
        update()
    }

    func turnOff() {
        isManualOn = false
        manualEnd = nil
        scheduleEndTimer()
        if isHeldForAgents {
            isHeldForAgents = false
            isAgentHoldSuppressed = true
        }
        Log.engine.notice("Turned off")
        update()
    }

    func toggle() {
        isAwake ? turnOff() : turnOn(minutes: prefs.defaultMinutes)
    }

    /// Lets go of everything and sleeps right away. While the lid hold is on, Apple menu > Sleep
    /// does nothing, so this is the way to sleep by hand.
    func sleepNow() {
        turnOff()
        SystemState.sleepNow()
    }

    private func scheduleEndTimer() {
        endTimer?.invalidate()
        endTimer = nil
        guard let manualEnd else { return }
        endTimer = Timer.scheduledTimer(withTimeInterval: max(manualEnd.timeIntervalSinceNow, 0), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Log.engine.notice("Time is up")
                self.isManualOn = false
                self.manualEnd = nil
                self.update()
            }
        }
    }

    // MARK: - Decisions

    private var isTooHot: Bool {
        guard prefs.heatGuard else { return false }
        let thermal = SystemState.thermal
        if thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return true }
        // A closed MacBook in a bag can't shed heat, so it gives up at the first warm level
        return thermal.rawValue >= ProcessInfo.ThermalState.fair.rawValue && isLidHeld && SystemState.isClosedInBag
    }

    private var isBatteryLow: Bool {
        guard prefs.batteryGuard, let battery = SystemState.battery, battery.isOnBattery else { return false }
        return battery.percent <= prefs.batteryGuardPercent
    }

    func update() {
        if prefs.agentMode { agents.start() } else { agents.stop() }
        updateAgentHold()

        if isAwake, isTooHot {
            cut(.heat)
        } else if isAwake, isBatteryLow {
            cut(.battery)
        }
        apply()
        onChange?()
    }

    private func updateAgentHold() {
        guard prefs.agentMode else {
            isHeldForAgents = false
            isAgentHoldSuppressed = false
            return
        }
        if agents.isAnyWorking {
            if !isHeldForAgents, !isAgentHoldSuppressed, !isTooHot, !isBatteryLow {
                Log.engine.notice("Agents are working, staying awake")
                isHeldForAgents = true
                lastCutoff = nil
            }
            return
        }
        // Quiet for the whole grace period: the work is done
        let grace = TimeInterval(max(prefs.agentGraceMinutes, 1) * 60)
        let quietFor = Date().timeIntervalSince(agents.lastWorkingAt ?? .distantPast)
        guard quietFor >= grace, isHeldForAgents || isAgentHoldSuppressed else { return }
        if isHeldForAgents { Log.engine.notice("Agents are done, letting go") }
        isHeldForAgents = false
        isAgentHoldSuppressed = false
    }

    private func cut(_ reason: Cutoff) {
        Log.engine.notice("Turning off because of \(reason == .heat ? "heat" : "low battery", privacy: .public)")
        lastCutoff = reason
        isManualOn = false
        manualEnd = nil
        scheduleEndTimer()
        if isHeldForAgents {
            isHeldForAgents = false
            isAgentHoldSuppressed = true
        }
    }

    /// Makes the system match the decisions above.
    private func apply() {
        let lidClosed = SystemState.isLidClosed
        let inBag = SystemState.isClosedInBag
        let wantsLid = isAwake && isLidSetUp && prefs.lidClosed && !isShuttingDown

        // A closed Mac that isn't allowed to stay up closed should sleep, not be held by an assertion
        systemAssertion.set(isAwake && !(inBag && !wantsLid))
        // Agents can work with a dark screen, only the user's own session keeps it lit
        displayAssertion.set(isManualOn && prefs.keepDisplayOn && !lidClosed)

        if wantsLid != isLidHeld, Date() >= lidRetryAfter {
            if wantsLid {
                if LidHold.setSleepDisabled(true) {
                    isLidHeld = true
                } else {
                    // The rule may be gone (removed by hand), check before trying again
                    isLidSetUp = LidHold.isSetUp
                    lidRetryAfter = Date().addingTimeInterval(60)
                }
            } else if LidHold.setSleepDisabled(false) {
                isLidHeld = false
                // Letting go of disablesleep with the lid shut doesn't sleep the Mac by itself
                if inBag, !isShuttingDown { SystemState.sleepNow() }
            } else {
                Log.lid.error("Could not turn sleep back on, trying again soon")
                lidRetryAfter = Date().addingTimeInterval(15)
            }
        }

        let heldInBag = isLidHeld && inBag
        if heldInBag, !wasInBag {
            Log.lid.notice("Lid closed while held, turning the display off")
            SystemState.displaySleepNow()
        }
        // Low Power Mode only matters on battery, and only the battery profile is changed
        let wantsLowPower = heldInBag && prefs.lowPowerWhileClosed && SystemState.battery?.isOnBattery == true
        if wantsLowPower, !LidHold.lowPowerForcedByUs, !SystemState.isLowPowerModeOn {
            LidHold.setLowPowerMode(true)
        } else if !wantsLowPower, LidHold.lowPowerForcedByUs {
            LidHold.setLowPowerMode(false)
        }
        wasInBag = heldInBag
    }
}
