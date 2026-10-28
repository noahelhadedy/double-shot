import Testing
@testable import DoubleShot

/// The lid hold: pmset changes, their retries, and letting go when it matters.
@MainActor
@Suite struct LidSafetyTests {
    let h = EngineHarness()

    /// On for an hour with lid closed mode set up, then the lid closes on battery with no display.
    private func closeTheLidWhileOn() {
        h.engine.refreshLidSetup()
        h.engine.turnOn(minutes: 60)
        h.mac.isClosedInBag = true
        h.wait(5)
    }

    private func trigger(_ cutoff: AwakeEngine.Cutoff) {
        switch cutoff {
        case .heat: h.mac.thermal = .fair // the first warm level is enough in a bag
        case .battery: h.mac.battery = SystemState.Battery(percent: 15, isOnBattery: true)
        }
    }

    @Test func holdsTheLidDarkensTheDisplayAndSavesPowerInTheBag() {
        closeTheLidWhileOn()
        #expect(h.engine.isLidHeld)
        #expect(h.mac.sleepDisabled)
        #expect(h.mac.isLowPowerModeOn)
        #expect(h.mac.displaySleeps == 1)
        #expect(h.mac.keepAwake)
        #expect(!h.mac.keepDisplayOn)
    }

    @Test func checkingAgainRepeatsNoChange() {
        closeTheLidWhileOn()
        for _ in 0..<6 { h.wait(5) }
        #expect(h.mac.pmsetCalls == ["disablesleep 1", "lowpowermode 1"])
        #expect(h.mac.displaySleeps == 1)
    }

    /// Low Power Mode is optional, letting go of the lid is not: its failure must not hold that up.
    @Test(arguments: [AwakeEngine.Cutoff.heat, .battery])
    func aFailedLowPowerModeCallDoesNotDelayLettingGo(_ cutoff: AwakeEngine.Cutoff) {
        h.mac.failing = ["lowpowermode 1"]
        closeTheLidWhileOn()
        #expect(!h.mac.isLowPowerModeOn)

        trigger(cutoff)
        h.wait(5)
        #expect(h.engine.lastCutoff == cutoff)
        #expect(!h.engine.isLidHeld)
        #expect(!h.mac.sleepDisabled)
        #expect(h.mac.sleeps == 1, "let go in a bag, so it's put to sleep")
    }

    @Test func aFailedLowPowerModeCallIsRetriedLaterNotOnEveryCheck() {
        h.mac.failing = ["lowpowermode 1"]
        closeTheLidWhileOn()
        h.wait(5)
        h.wait(5)
        #expect(h.mac.calls("lowpowermode 1") == 1)

        h.mac.failing = []
        h.wait(60)
        #expect(h.mac.calls("lowpowermode 1") == 2)
        #expect(h.mac.isLowPowerModeOn)
    }

    @Test func aFailedReleaseIsRetriedAndNotTakenAsDone() {
        closeTheLidWhileOn()
        h.mac.failing = ["disablesleep 0"]
        h.engine.turnOff()
        #expect(h.engine.isLidHeld, "still held, since sleep is still disabled")
        #expect(h.mac.sleepDisabled)

        h.mac.failing = []
        h.wait(5)
        #expect(h.mac.calls("disablesleep 0") == 1, "no sudo call on every check")
        h.wait(15)
        #expect(h.mac.calls("disablesleep 0") == 2)
        #expect(!h.engine.isLidHeld)
        #expect(!h.mac.sleepDisabled)
        #expect(h.mac.sleeps == 1)
    }

    @Test(arguments: [AwakeEngine.Cutoff.heat, .battery])
    func aFailedReleaseDuringACutoffIsRetried(_ cutoff: AwakeEngine.Cutoff) {
        closeTheLidWhileOn()
        h.mac.failing = ["disablesleep 0"]
        trigger(cutoff)
        h.wait(5)
        #expect(h.mac.sleepDisabled)

        h.mac.failing = []
        h.wait(20)
        #expect(!h.engine.isLidHeld)
        #expect(!h.mac.sleepDisabled)
        #expect(h.mac.sleeps == 1)
    }

    @Test func quittingWhileHeldInTheBagUndoesEverythingAndSleeps() {
        closeTheLidWhileOn()
        h.engine.shutdown()
        #expect(!h.mac.sleepDisabled)
        #expect(!h.mac.isLowPowerModeOn)
        #expect(!h.mac.keepAwake)
        #expect(!h.mac.heldInBag)
        #expect(h.mac.sleeps == 1)
    }
}
