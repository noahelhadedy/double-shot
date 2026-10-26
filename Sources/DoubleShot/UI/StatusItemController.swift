import AppKit

/// The cup in the menu bar. Click for the panel; Option click (or a plain click, if set in
/// Settings) switches it on and off without opening anything.
@MainActor
final class StatusItemController: NSObject {
    private let engine: AwakeEngine
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: PanelController

    static let durations: [(minutes: Int, title: String)] = [
        (15, "15 minutes"), (30, "30 minutes"), (60, "1 hour"), (120, "2 hours"),
        (180, "3 hours"), (300, "5 hours"), (480, "8 hours"), (0, "Until I turn it off"),
    ]

    init(engine: AwakeEngine, openSettings: @escaping (SettingsTab) -> Void) {
        self.engine = engine
        self.panel = PanelController(engine: engine, openSettings: openSettings)
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refresh()
    }

    func refresh() {
        guard let button = statusItem.button else { return }
        button.image = Self.menuBarImage(awake: engine.isAwake, agents: engine.isHeldForAgents && !engine.isManualOn)
        button.image?.accessibilityDescription = statusLine
        button.setAccessibilityLabel("Double Shot, \(statusLine)")
        button.toolTip = statusLine
    }

    /// A mug sized like Apple's own menu bar icons (Wi-Fi, battery): empty when off, full when on,
    /// whether you or your agents turned it on.
    static func menuBarImage(awake: Bool, agents: Bool) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        let mug = NSImage(systemSymbolName: awake ? "mug.fill" : "mug", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        mug?.isTemplate = true
        return mug
    }

    func showPanel() {
        guard let button = statusItem.button, !panel.isShown else { return }
        panel.show(below: button)
    }

    @objc private func clicked() {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        let quickToggle = event?.modifierFlags.contains(.option) == true
            || (engine.prefs.leftClickToggles && !isRightClick)
        if quickToggle {
            panel.close()
            engine.toggle()
        } else {
            panel.toggle(below: button)
        }
    }

    var statusLine: String {
        if engine.isManualOn {
            guard let end = engine.manualEnd else { return "Awake until you turn it off" }
            return "Awake for \(Self.format(remaining: end.timeIntervalSinceNow)) more"
        }
        if engine.isHeldForAgents {
            let names = engine.agents.running.filter(\.isWorking).map(\.kind.name)
            return names.isEmpty ? "Awake while your agents finish up" : "Awake while \(ListFormatter.localizedString(byJoining: names)) works"
        }
        switch engine.lastCutoff {
        case .heat: return "Turned off, your Mac got too warm"
        case .battery: return "Turned off, battery is low"
        case nil: break
        }
        if engine.isAgentHoldSuppressed { return "Off until your agents finish" }
        return "Off, your Mac sleeps as usual"
    }

    static func format(remaining seconds: TimeInterval) -> String {
        let minutes = max(Int((seconds / 60).rounded(.up)), 1)
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}
