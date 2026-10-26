import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = AwakeEngine()
    private var statusItem: StatusItemController?
    private lazy var settings = SettingsWindowController(engine: engine)
    private var welcome: WelcomeWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies would fight over the same sleep setting, so the second one bows out
        if let bundleID = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0 != NSRunningApplication.current }) {
            other.activate()
            exit(0)
        }
        NSApp.mainMenu = Self.makeMainMenu()
        statusItem = StatusItemController(engine: engine) { [weak self] tab in
            self?.settings.show(tab)
        }
        engine.onChange = { [weak self] in self?.statusItem?.refresh() }
        engine.start()
        if !engine.prefs.welcomeDone { showWelcome() }
    }

    func showWelcome(at step: WelcomeView.Step = .hello) {
        welcome?.close()
        welcome = WelcomeWindowController(engine: engine, startAt: step) { [weak self] openPanel in
            self?.engine.prefs.welcomeDone = true
            self?.welcome = nil
            if openPanel { self?.statusItem?.showPanel() }
        }
        welcome?.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
    }

    /// doubleshot://on?minutes=30, doubleshot://off, doubleshot://toggle
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "doubleshot" {
            let command = url.host() ?? ""
            let minutes = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "minutes" }?.value.flatMap(Int.init)
            switch command {
            case "on": engine.turnOn(minutes: minutes ?? engine.prefs.defaultMinutes)
            case "off": engine.turnOff()
            case "toggle": engine.toggle()
            case "panel": statusItem?.showPanel()
            case "welcome":
                let step = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "step" }?.value.flatMap(WelcomeView.Step.init(rawValue:))
                showWelcome(at: step ?? .hello)
            case "settings":
                let tab = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "tab" }?.value.flatMap(SettingsTab.init(rawValue:))
                settings.show(tab ?? .general)
            default: Log.engine.error("Unknown command \(url.absoluteString, privacy: .public)")
            }
        }
    }

    /// Never shown for a menu bar app, but it's what makes Cmd+Q, Cmd+W and copy work in Settings.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let item = NSMenuItem()
            item.submenu = menu
            main.addItem(item)
        }
        submenu("Double Shot", [NSMenuItem(title: "Quit Double Shot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")])
        submenu("Edit", [
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ])
        submenu("Window", [NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")])
        return main
    }

    // Opening the app again while it runs shows Settings, the only window it has
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show(.general)
        return false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// `kill`, logout and Activity Monitor's Quit send signals, not a menu Quit. Route them through
// terminate so sleep is never left disabled behind us.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
signal(SIGHUP, SIG_IGN)
let signalSources = [SIGTERM, SIGINT, SIGHUP].map { number in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    return source
}

app.setActivationPolicy(.accessory)
app.run()
