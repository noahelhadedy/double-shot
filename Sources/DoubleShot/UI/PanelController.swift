import AppKit
import SwiftUI

/// A borderless glass panel that drops down from the menu bar, closes on any outside click or Esc.
@MainActor
final class PanelController {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let panel: Panel
    private let engine: AwakeEngine
    private let openSettings: (SettingsTab) -> Void
    private var outsideClickMonitor: Any?
    private var insideClickMonitor: Any?
    private var escMonitor: Any?
    private var spaceObserver: NSObjectProtocol?
    private weak var button: NSStatusBarButton?
    private var anchor: NSRect = .zero
    private var resizeObserver: NSObjectProtocol?

    var isShown: Bool { panel.isVisible }

    init(engine: AwakeEngine, openSettings: @escaping (SettingsTab) -> Void) {
        panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow

        self.engine = engine
        self.openSettings = openSettings

        // Content grows and shrinks (agents come and go): keep the top edge under the menu bar
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeUnderAnchor() }
        }
    }

    func toggle(below button: NSStatusBarButton) {
        isShown ? close() : show(below: button)
    }

    func show(below button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        self.button = button
        anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        // The content only exists while the panel is open, so its animations never run in the background
        panel.contentViewController = makeContent()
        placeUnderAnchor()
        button.highlight(true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        // Clicks in our own windows (Settings, Welcome) close it too, except the cup that toggles it
        insideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window !== self.panel, event.window !== self.button?.window else { return }
                self.close()
            }
            return event
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.close() }
            return nil
        }
    }

    func close() {
        guard isShown else { return }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let insideClickMonitor { NSEvent.removeMonitor(insideClickMonitor) }
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        outsideClickMonitor = nil
        insideClickMonitor = nil
        escMonitor = nil
        spaceObserver = nil
        button?.highlight(false)
        panel.orderOut(nil)
        panel.contentViewController = nil
    }

    private func makeContent() -> NSViewController {
        let root = PanelView(engine: engine,
                             openSettings: { [weak self] tab in
                                 self?.close()
                                 self?.openSettings(tab)
                             },
                             quit: { NSApp.terminate(nil) })
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = .preferredContentSize
        return hosting
    }

    private func placeUnderAnchor() {
        guard anchor != .zero else { return }
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = anchor.minY - size.height - 6
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
