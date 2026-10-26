import AppKit
import SwiftUI

/// A borderless glass panel that drops down from the menu bar, closes on any outside click or Esc.
@MainActor
final class PanelController {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let panel: Panel
    private var outsideClickMonitor: Any?
    private var escMonitor: Any?
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

        let root = PanelView(engine: engine,
                             openSettings: { [weak self] tab in
                                 self?.close()
                                 openSettings(tab)
                             },
                             quit: { NSApp.terminate(nil) })
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = .preferredContentSize
        panel.contentViewController = hosting

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
        anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        placeUnderAnchor()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
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
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        outsideClickMonitor = nil
        escMonitor = nil
        panel.orderOut(nil)
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
