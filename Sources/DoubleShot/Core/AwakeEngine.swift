import AppKit
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
    /// Why it let go by itself. Agents still working pick up again once the reason is over:
    /// cooled down or plugged in. Not the same as being turned off by hand.
    private(set) var lastCutoff: Cutoff?
    private(set) var isLidSetUp = false

    var isAwake: Bool { isManualOn || isHeldForAgents }

    let agents = AgentMonitor()
    let updates = UpdateChecker()
    let prefs: Preferences

    /// Fired whenever anything visible changed, for the menu bar icon.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let system: PowerSystem
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var endTimer: Timer?
    @ObservationIgnored private var wasInBag = false
    @ObservationIgnored private var isShuttingDown = false
    /// Logout, restart or shut down in progress: quitting must never put the Mac to sleep then.
    @ObservationIgnored private var isPoweringOff = false
    /// After a failed pmset call, wait before trying again instead of calling sudo every tick.
    @ObservationIgnored private var lidRetryAfter = Date.distantPast
    /// Its own clock, so a failing Low Power Mode call never delays letting go of the lid (heat, work done).
    @ObservationIgnored private var lowPowerRetryAfter = Date.distantPast

    /// `system` is the Mac and `now` its clock; tests pass a fake of each.
    init(prefs: Preferences = .shared, system: PowerSystem = LivePowerSystem(), now: @escaping () -> Date = { Date() }) {
        self.prefs = prefs
        self.system = system
        self.now = now
    }

    // MARK: - Life cycle

    func start() {
        isLidSetUp = system.isLidSetUp
        // A previous run that crashed may have left sleep disabled or Low Power Mode on
        system.cleanUpLeftovers()

        prefs.onChange = { [weak self] in
            self?.syncServices()
            self?.update()
        }
        agents.onUpdate = { [weak self] in self?.update() }
        syncServices()

        tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPoweringOff = true }
        }

        if prefs.turnOnAtLaunch { turnOn(minutes: prefs.defaultMinutes) }
        update()
    }

    /// Agent watching and update checks run while their settings are on.
    private func syncServices() {
        if prefs.agentMode { agents.start() } else { agents.stop() }
        if prefs.checkForUpdates { updates.start() } else { updates.stop() }
    }

    /// Everything back to normal, called on quit. A Mac held shut in a bag goes to sleep, since
    /// nothing else will put it down; during a logout or restart it only undoes our changes.
    func shutdown() {
        let wasHeldInBag = isLidHeld && system.isClosedInBag
        isShuttingDown = true
        isManualOn = false
        isHeldForAgents = false
        agents.stop()
        apply()
        system.cleanUpLeftovers()
        if wasHeldInBag, !isPoweringOff { system.sleepNow() }
    }

    func refreshLidSetup() {
        isLidSetUp = system.isLidSetUp
        // Removing the permission turns sleep back on as root, so there is no hold left to undo
        if !isLidSetUp, !system.sleepDisabledByUs {
            isLidHeld = false
            lidRetryAfter = .distantPast
        }
        update()
    }

    // MARK: - User actions

    /// minutes == 0 means until turned off.
    func turnOn(minutes: Int) {
        // At most a week; anything else (negative, huge numbers from a URL) is until turned off
        let minutes = (1...10_080).contains(minutes) ? minutes : 0
        isManualOn = true
        lastCutoff = nil
        manualMinutes = minutes
        manualEnd = minutes > 0 ? now().addingTimeInterval(TimeInterval(minutes * 60)) : nil
        scheduleEndTimer()
        Log.engine.notice("Turned on for \(minutes) minutes (0 = until turned off)")
        update()
    }

    func turnOff() {
        isManualOn = false
        manualEnd = nil
        scheduleEndTimer()
        // Also while a cutoff has let go of them (maybe between two turns), so they don't pick up
        // again when it's over
        if isHeldForAgents || (prefs.agentMode && agentsWorkedLately) {
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
        system.sleepNow()
    }

    private func scheduleEndTimer() {
        endTimer?.invalidate()
        endTimer = nil
        guard let manualEnd else { return }
        endTimer = Timer.scheduledTimer(withTimeInterval: max(manualEnd.timeIntervalSince(now()), 0), repeats: false) { [weak self] _ in
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
        let thermal = system.thermal
        if thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return true }
        // A closed MacBook in a bag can't shed heat, so it gives up at the first warm level
        return thermal.rawValue >= ProcessInfo.ThermalState.fair.rawValue && isLidHeld && system.isClosedInBag
    }

    /// Too hot once held where the Mac is now: in a bag the first warm level counts whenever the lid
    /// would be held shut, not only while it is. Letting go of the lid alone makes a warm Mac in a bag
    /// look fine, so taking a hold and ending a heat cutoff go by this.
    private var isTooHotToHold: Bool {
        isTooHot || (prefs.heatGuard && system.thermal.rawValue >= ProcessInfo.ThermalState.fair.rawValue
            && system.isClosedInBag && isLidSetUp && prefs.lidClosed)
    }

    private var isBatteryLow: Bool {
        guard prefs.batteryGuard, let battery = system.battery, battery.isOnBattery else { return false }
        return battery.percent <= prefs.batteryGuardPercent
    }

    /// How long agents must be quiet before their work counts as done.
    private var grace: TimeInterval {
        TimeInterval(max(prefs.agentGraceMinutes, 1) * 60)
    }

    /// Working, or quiet for less than the grace period, like a model thinking between turns.
    private var agentsWorkedLately: Bool {
        agents.isAnyWorking || now().timeIntervalSince(agents.lastWorkingAt ?? .distantPast) < grace
    }

    /// AgentMonitor reports every 10 seconds, so an older report means the Mac slept since.
    private static let agentReportLifetime: TimeInterval = 60

    func update() {
        // Timers don't count time asleep, so a session can end while the Mac sleeps and the timer fires late
        if isManualOn, let manualEnd, manualEnd <= now() {
            Log.engine.notice("Time is up")
            isManualOn = false
            self.manualEnd = nil
            scheduleEndTimer()
        }
        // A cutoff ends once its reason has: plugged in, or cool enough to be held where the Mac is
        // now. A reading back above the limit on battery isn't plugging in, it ticks up as the load drops.
        if !isAwake, let lastCutoff {
            let over = lastCutoff == .battery ? !prefs.batteryGuard || system.battery?.isOnBattery != true : !isTooHotToHold
            if over { self.lastCutoff = nil }
        }
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
            guard !isHeldForAgents, !isAgentHoldSuppressed, lastCutoff == nil else { return }
            // Right after a sleep this is still the report from before it; wait for the next check
            guard now().timeIntervalSince(agents.lastWorkingAt ?? .distantPast) < Self.agentReportLifetime else { return }
            // Too hot or low already: don't start, and say why
            if isTooHotToHold {
                lastCutoff = .heat
            } else if isBatteryLow {
                lastCutoff = .battery
            } else {
                Log.engine.notice("Agents are working, staying awake")
                isHeldForAgents = true
            }
            return
        }
        // Quiet for the whole grace period: the work is done
        let quietFor = now().timeIntervalSince(agents.lastWorkingAt ?? .distantPast)
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
        // Not a pause: agents still working pick up again once the reason is over
        isHeldForAgents = false
    }

    /// Makes the system match the decisions above.
    private func apply() {
        let inBag = system.isClosedInBag
        let wantsLid = isAwake && isLidSetUp && prefs.lidClosed && !isShuttingDown

        // A closed Mac that isn't allowed to stay up closed should sleep, not be held by an assertion.
        // Agents can work with a dark screen, only the user's own session keeps it lit
        system.setAssertions(keepAwake: isAwake && !(inBag && !wantsLid),
                             keepDisplayOn: isManualOn && prefs.keepDisplayOn && !inBag)

        if wantsLid != isLidHeld, now() >= lidRetryAfter {
            if wantsLid {
                if system.setSleepDisabled(true) {
                    isLidHeld = true
                } else {
                    // The rule may be gone (removed by hand), check before trying again
                    isLidSetUp = system.isLidSetUp
                    lidRetryAfter = now().addingTimeInterval(60)
                }
            } else if system.setSleepDisabled(false) {
                isLidHeld = false
                // Letting go of disablesleep with the lid shut doesn't sleep the Mac by itself
                if inBag, !isShuttingDown { system.sleepNow() }
            } else {
                Log.lid.error("Could not turn sleep back on, trying again soon")
                lidRetryAfter = now().addingTimeInterval(15)
            }
        }

        let heldInBag = isLidHeld && inBag
        if heldInBag, !wasInBag {
            Log.lid.notice("Lid closed while held, turning the display off")
            system.displaySleepNow()
        }
        // Low Power Mode only matters on battery, and only the battery profile is changed
        let wantsLowPower = heldInBag && prefs.lowPowerWhileClosed && system.battery?.isOnBattery == true
        if wantsLowPower, !system.lowPowerForcedByUs, !system.isLowPowerModeOn, now() >= lowPowerRetryAfter {
            if !system.setLowPowerMode(true) { lowPowerRetryAfter = now().addingTimeInterval(60) }
        } else if !wantsLowPower, system.lowPowerForcedByUs {
            system.setLowPowerMode(false)
        }
        wasInBag = heldInBag
        system.heldInBag = heldInBag && !isShuttingDown
    }
}
