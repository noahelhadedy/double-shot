import Foundation
import IOKit.pwr_mgt

/// One IOKit power assertion. Holding it stops idle sleep, releasing it lets the Mac sleep again.
@MainActor
final class PowerAssertion {
    private let type: String
    private let reason: String
    private var id: IOPMAssertionID = 0

    var isHeld: Bool { id != 0 }

    init(type: String, reason: String) {
        self.type = type
        self.reason = reason
    }

    func set(_ held: Bool) {
        held ? hold() : release()
    }

    func hold() {
        guard !isHeld else { return }
        var newID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &newID)
        if result == kIOReturnSuccess {
            id = newID
        } else {
            Log.power.error("Could not create \(self.type, privacy: .public) assertion: \(result)")
        }
    }

    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(id)
        id = 0
    }
}
