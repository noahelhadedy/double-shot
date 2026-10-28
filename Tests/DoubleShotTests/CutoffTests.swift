import Foundation
import Testing
@testable import DoubleShot

/// Heat and battery cutoffs against the user's own pause, while agents work.
@MainActor
@Suite struct CutoffTests {
    let h = EngineHarness()

    private let lowBattery = SystemState.Battery(percent: 15, isOnBattery: true)
    private let pluggedIn = SystemState.Battery(percent: 15, isOnBattery: false)

    @Test func turningOffDuringARunStaysOffUntilTheAgentsGoQuiet() {
        h.agents(working: true)
        #expect(h.engine.isHeldForAgents)
        h.engine.turnOff()
        h.wait(5)
        h.agents(working: true)
        #expect(!h.engine.isAwake)
        #expect(h.engine.isAgentHoldSuppressed)

        h.agents(working: false)
        h.wait(3 * 60)
        #expect(!h.engine.isAgentHoldSuppressed)
        h.agents(working: true)
        #expect(h.engine.isHeldForAgents)
    }

    @Test func aShortQuietSpellKeepsTheHoldAndTheGracePeriodEndsIt() {
        h.agents(working: true)
        h.agents(working: false)
        h.wait(60)
        #expect(h.engine.isHeldForAgents)
        h.agents(working: true)
        h.agents(working: false)
        h.wait(3 * 60)
        #expect(!h.engine.isAwake)
    }

    /// Agents held and the lid closed in a bag, on battery, with lid closed mode set up.
    private func holdInTheBag() {
        h.engine.refreshLidSetup()
        h.agents(working: true)
        h.mac.isClosedInBag = true
        h.wait(5)
    }

    /// With the lid open only the serious level is too hot, so warm is cool enough to pick up again.
    @Test func withTheLidOpenAgentsPickUpOnceItIsNoLongerTooHot() {
        h.agents(working: true)
        h.mac.thermal = .serious
        h.wait(5)
        #expect(!h.engine.isAwake)
        #expect(h.engine.lastCutoff == .heat)
        #expect(!h.engine.isAgentHoldSuppressed, "a cutoff isn't a pause by the user")

        h.mac.thermal = .fair
        h.wait(5)
        #expect(h.engine.isHeldForAgents)
        #expect(h.engine.lastCutoff == nil)
    }

    @Test func turningOffTheHeatGuardEndsAHeatCutoff() {
        h.agents(working: true)
        h.mac.thermal = .serious
        h.wait(5)
        h.prefs.heatGuard = false
        h.wait(5)
        #expect(h.engine.isHeldForAgents)
        #expect(h.engine.lastCutoff == nil)
    }

    @Test func agentsPickUpAgainOncePluggedIn() {
        h.agents(working: true)
        h.mac.battery = lowBattery
        h.wait(5)
        #expect(!h.engine.isAwake)
        #expect(h.engine.lastCutoff == .battery)
        #expect(!h.engine.isAgentHoldSuppressed)

        h.mac.battery = pluggedIn
        h.wait(5)
        #expect(h.engine.isHeldForAgents)
        #expect(h.engine.lastCutoff == nil)
    }

    /// On battery the reading can tick back up a point once the load drops. That isn't plugging in.
    @Test func aBatteryReadingJustAboveTheLimitDoesNotBringTheHoldBack() {
        holdInTheBag()
        h.mac.battery = SystemState.Battery(percent: 20, isOnBattery: true)
        h.wait(5)
        #expect(h.engine.lastCutoff == .battery)
        #expect(h.mac.sleeps == 1)

        h.mac.battery = SystemState.Battery(percent: 21, isOnBattery: true)
        h.wait(5)
        #expect(!h.engine.isAwake)
        #expect(h.engine.lastCutoff == .battery)
        #expect(h.mac.calls("disablesleep 1") == 1)
    }

    /// Letting go of the lid makes a warm Mac in a bag look fine, but holding it shut again would
    /// make it too hot at once.
    @Test func pluggingInWhileWarmInABagDoesNotHoldItShutAgain() {
        holdInTheBag()
        h.mac.battery = lowBattery
        h.wait(5)
        #expect(!h.engine.isLidHeld)

        h.mac.thermal = .fair
        h.mac.battery = pluggedIn
        h.wait(5)
        #expect(!h.engine.isAwake)
        #expect(h.engine.lastCutoff == .heat)
        #expect(h.mac.calls("disablesleep 1") == 1)

        h.mac.thermal = .nominal
        h.wait(5)
        #expect(h.engine.isLidHeld)
    }

    /// Your own session, no agents: the cutoff (and its note) lasts while holding the Mac shut in the
    /// bag would still be too hot, even though nothing is held now.
    @Test func aHeatCutoffInABagLastsWhileItIsWarm() {
        h.engine.refreshLidSetup()
        h.engine.turnOn(minutes: 60)
        h.mac.isClosedInBag = true
        h.wait(5)
        h.mac.thermal = .fair
        h.wait(5)
        #expect(h.engine.lastCutoff == .heat)
        #expect(!h.engine.isLidHeld)

        h.wait(5)
        #expect(h.engine.lastCutoff == .heat)
        h.mac.thermal = .nominal
        h.wait(5)
        #expect(h.engine.lastCutoff == nil)
    }

    /// The agents' last report is from before the Mac slept: only a check after waking brings them back.
    @Test func afterASleepOnlyAFreshCheckBringsTheAgentsBack() {
        holdInTheBag()
        h.mac.thermal = .fair
        h.wait(5)
        #expect(h.mac.sleeps == 1)

        h.now += 30 * 60.0 // asleep: nothing runs
        h.mac.thermal = .nominal
        h.wait(5)
        #expect(!h.engine.isAwake)
        #expect(h.mac.calls("disablesleep 1") == 1)

        h.agents(working: true)
        #expect(h.engine.isLidHeld)
    }

    @Test func turningOffDuringACutoffBetweenTurnsStillPauses() {
        h.agents(working: true)
        h.mac.thermal = .serious
        h.wait(5)
        // The model is thinking: the last check found no work, but the grace period isn't over
        h.agents(working: false)
        h.wait(60)
        h.engine.turnOff()

        h.agents(working: true)
        h.mac.thermal = .nominal
        h.wait(5)
        #expect(!h.engine.isAwake)
        #expect(h.engine.isAgentHoldSuppressed)
    }

    @Test func aPauseFromBeforeACutoffOutlastsIt() {
        h.agents(working: true)
        h.engine.turnOff()
        h.engine.turnOn(minutes: 30)
        h.mac.thermal = .serious
        h.wait(5)
        #expect(!h.engine.isAwake)
        #expect(h.engine.lastCutoff == .heat)

        h.mac.thermal = .nominal
        h.wait(5)
        #expect(h.engine.lastCutoff == nil)
        #expect(!h.engine.isAwake)
        #expect(h.engine.isAgentHoldSuppressed)
    }

    @Test func turningOffDuringACutoffKeepsAgentsOffAfterIt() {
        h.agents(working: true)
        h.mac.thermal = .serious
        h.wait(5)
        h.engine.turnOff()

        h.mac.thermal = .nominal
        h.wait(5)
        #expect(!h.engine.isAwake)
        #expect(h.engine.isAgentHoldSuppressed)
    }

    @Test func overlappingCutoffsWaitForBoth() {
        h.agents(working: true)
        h.mac.thermal = .serious
        h.wait(5)
        h.mac.battery = lowBattery
        h.mac.thermal = .nominal
        h.wait(5)
        #expect(!h.engine.isAwake)
        #expect(h.engine.lastCutoff == .battery, "the reason still in the way")

        h.mac.battery = pluggedIn
        h.wait(5)
        #expect(h.engine.isHeldForAgents)
    }

    @Test func agentsGoingQuietAndBackDoNotEndACutoff() {
        h.agents(working: true)
        h.mac.thermal = .serious
        h.wait(5)
        h.agents(working: false)
        h.wait(4 * 60)
        h.agents(working: true)
        #expect(!h.engine.isAwake)
        #expect(h.engine.lastCutoff == .heat)
    }

    @Test func agentsStartingOnAHotMacSayWhyTheyAreNotHeld() {
        h.mac.thermal = .serious
        h.agents(working: true)
        #expect(!h.engine.isAwake)
        #expect(h.engine.lastCutoff == .heat)
    }

    /// Letting go of the lid makes a warm Mac in a bag look fine again (the warm limit only applies
    /// while held), so only cooling down may bring the hold back.
    @Test func aWarmMacInABagIsNotHeldAgainBeforeItCools() {
        h.engine.refreshLidSetup()
        h.agents(working: true)
        h.mac.isClosedInBag = true
        h.wait(5)
        #expect(h.engine.isLidHeld)

        h.mac.thermal = .fair
        h.wait(5)
        #expect(!h.engine.isLidHeld)
        h.wait(5)
        h.wait(5)
        #expect(!h.engine.isLidHeld)
        #expect(h.mac.calls("disablesleep 1") == 1)
        #expect(h.mac.sleeps == 1)
    }

    @Test func thePanelSaysWhyAgentsAreOff() {
        h.agents(working: true)
        h.mac.thermal = .serious
        h.wait(5)
        #expect(PanelView.agentDetail(h.engine) == "Stopped because your Mac got warm.")
        #expect(PanelView.sentence(h.engine) == "Agents wait until your Mac cools down.")

        h.mac.thermal = .nominal
        h.wait(5)
        #expect(PanelView.agentDetail(h.engine) == "Claude Code is working. Staying up.")

        h.engine.turnOff()
        #expect(PanelView.agentDetail(h.engine) == "Paused by you until they finish.")
        #expect(PanelView.sentence(h.engine) == "Paused until your agents finish.")
    }

    @Test func thePanelSaysWhenPluggingInBringsThemBack() {
        h.agents(working: true)
        h.mac.battery = lowBattery
        h.wait(5)
        #expect(PanelView.agentDetail(h.engine) == "Stopped because the battery is low.")
        #expect(PanelView.sentence(h.engine) == "Agents wait until you plug in.")
    }

    /// Between turns, an agent starting to work again still waits for the Mac to cool down.
    @Test func duringAQuietCutoffThePanelDoesNotPromiseToWakeForAgents() {
        h.agents(working: true)
        h.mac.thermal = .serious
        h.wait(5)
        h.agents(working: false)
        #expect(PanelView.sentence(h.engine) == "Agents wait until your Mac cools down.")
    }
}
