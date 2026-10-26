import AppKit
import SwiftUI

/// Shows the welcome steps once, on the first launch.
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    private var onFinish: ((Bool) -> Void)?

    init(engine: AwakeEngine, startAt step: WelcomeView.Step = .hello, onFinish: @escaping (_ openPanel: Bool) -> Void) {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = "Welcome to Double Shot"
        super.init(window: window)
        self.onFinish = onFinish
        window.delegate = self
        let hosting = NSHostingController(rootView: WelcomeView(engine: engine, finish: { [weak self] openPanel in
            self?.complete(openPanel: openPanel)
        }, step: step))
        // The window takes exactly the view's size, header running under the title bar
        hosting.sizingOptions = .preferredContentSize
        window.contentViewController = hosting
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        window?.center()
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func complete(openPanel: Bool) {
        let finish = onFinish
        onFinish = nil
        close()
        finish?(openPanel)
    }

    // Closing the window counts as done too: it never comes back on its own
    func windowWillClose(_ notification: Notification) {
        let finish = onFinish
        onFinish = nil
        finish?(false)
    }
}
