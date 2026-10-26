import AppKit
import SwiftUI

/// A classic toolbar style settings window, one SwiftUI view per tab.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let tabs = NSTabViewController()

    init(engine: AwakeEngine) {
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.allowUserInteraction]
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)

        for tab in SettingsTab.allCases {
            let view: AnyView = switch tab {
            case .general: AnyView(GeneralSettingsView())
            case .lid: AnyView(LidSettingsView(engine: engine))
            case .agents: AnyView(AgentSettingsView(engine: engine))
            case .safety: AnyView(SafetySettingsView())
            case .about: AnyView(AboutView())
            }
            let hosting = NSHostingController(rootView: view)
            hosting.sizingOptions = .preferredContentSize
            let item = NSTabViewItem(viewController: hosting)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            item.identifier = tab.rawValue
            tabs.addTabViewItem(item)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ tab: SettingsTab) {
        if let index = tabs.tabViewItems.firstIndex(where: { ($0.identifier as? String) == tab.rawValue }) {
            tabs.selectedTabViewItemIndex = index
        }
        window?.title = tab.title
        window?.center()
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
