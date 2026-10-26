import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, lid, agents, safety, about

    var title: String {
        switch self {
        case .general: "General"
        case .lid: "Lid Closed"
        case .agents: "AI Agents"
        case .safety: "Safety"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .lid: "laptopcomputer"
        case .agents: "sparkles"
        case .safety: "shield.lefthalf.filled"
        case .about: "cup.and.saucer"
        }
    }
}

enum Links {
    static let website = URL(string: "https://noahelhadedy.com")!
    static let repository = URL(string: "https://github.com/noahelhadedy/double-shot")!
}

private let formWidth: CGFloat = 480

// MARK: - General

struct GeneralSettingsView: View {
    @Bindable var prefs = Preferences.shared
    @State private var startAtLogin = LoginItem.isEnabled
    @State private var loginMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open Double Shot when you log in", isOn: Binding(
                    get: { startAtLogin },
                    set: { enabled in
                        loginMessage = LoginItem.set(enabled)
                        startAtLogin = LoginItem.isEnabled
                    }
                ))
                Toggle("Turn on when Double Shot opens", isOn: $prefs.turnOnAtLaunch)
            } footer: {
                if let loginMessage {
                    HStack {
                        Text(loginMessage).foregroundStyle(.secondary)
                        if LoginItem.needsApproval {
                            Button("Open Login Items") { LoginItem.openSystemSettings() }
                                .controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Section {
                Picker("Clicking the cup keeps it awake", selection: $prefs.defaultMinutes) {
                    ForEach(StatusItemController.durations, id: \.minutes) { duration in
                        Text(duration.minutes == 0 ? "Until you turn it off" : "For \(duration.title)").tag(duration.minutes)
                    }
                }
                Toggle("Keep the display on too", isOn: $prefs.keepDisplayOn)
                Toggle("Clicking the cup switches it on and off", isOn: $prefs.leftClickToggles)
            } footer: {
                Text(prefs.leftClickToggles ? "Right click the cup for the panel." : "Option click the cup to switch it on and off without opening the panel.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("Automation") {
                LabeledContent("Turn on") { Text("doubleshot://on?minutes=30").textSelection(.enabled) }
                LabeledContent("Turn off") { Text("doubleshot://off").textSelection(.enabled) }
                LabeledContent("Toggle") { Text("doubleshot://toggle").textSelection(.enabled) }
                LabeledContent("Open the panel") { Text("doubleshot://panel").textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .frame(width: formWidth)
        .fixedSize()
        .onAppear {
            startAtLogin = LoginItem.isEnabled
            loginMessage = LoginItem.needsApproval ? "Waiting for your OK in System Settings." : nil
        }
    }
}

// MARK: - Lid closed

struct LidSettingsView: View {
    @Bindable var prefs = Preferences.shared
    let engine: AwakeEngine
    @State private var isWorking = false
    @State private var message: String?

    var body: some View {
        Form {
            if !SystemState.hasLid {
                Section {
                    Text("This Mac has no lid, so there is nothing to set up here.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    if engine.isLidSetUp {
                        LabeledContent {
                            Button("Remove Permission…") { change { LidHold.uninstall() } }
                                .disabled(isWorking)
                        } label: {
                            Label("Lid closed mode is ready", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("macOS always sleeps when you close the lid. To keep working, Double Shot needs your password once.")
                            Text("It adds one rule to /etc/sudoers.d that lets it switch sleep and Low Power Mode on and off. Nothing else.")
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Allow Lid Closed Mode…") { change { LidHold.install() } }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(isWorking)
                                if isWorking { ProgressView().controlSize(.small) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    if let message {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    Toggle("Keep working with the lid closed", isOn: $prefs.lidClosed)
                    Toggle("Use Low Power Mode while the lid is closed", isOn: $prefs.lowPowerWhileClosed)
                } footer: {
                    Text("Works for your own sessions and for AI agents. With the lid closed the display goes dark right away, and when the work is done Double Shot puts your Mac to sleep. While it's held, Apple menu > Sleep does nothing, so use Sleep Now in the panel. With an external display connected, a closed lid is a normal desk setup and these rules step aside.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(!engine.isLidSetUp)
            }
        }
        .formStyle(.grouped)
        .frame(width: formWidth)
        .fixedSize()
    }

    private func change(_ action: @escaping () -> LidHold.SetupResult) {
        isWorking = true
        message = nil
        Task { @MainActor in
            // Let the spinner show before the password dialog takes over
            try? await Task.sleep(for: .milliseconds(50))
            switch action() {
            case .done, .cancelled: break
            case .failed(let reason): message = reason
            }
            engine.refreshLidSetup()
            isWorking = false
        }
    }
}

// MARK: - Agents

struct AgentSettingsView: View {
    @Bindable var prefs = Preferences.shared
    let engine: AwakeEngine

    var body: some View {
        Form {
            Section {
                Toggle("Stay awake while AI agents work", isOn: $prefs.agentMode)
                Picker("Let go after they're quiet for", selection: $prefs.agentGraceMinutes) {
                    ForEach([1, 2, 3, 5, 10], id: \.self) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
                .disabled(!prefs.agentMode)
            } footer: {
                Text("No setup needed. Double Shot watches for agents that are actually working, not just open. A background run (claude -p, codex exec) counts until it ends. With lid closed mode on, they keep going with the lid shut too.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Right now") {
                if !prefs.agentMode {
                    Text("Turned off").foregroundStyle(.secondary)
                } else if engine.agents.running.isEmpty {
                    Text("No agents running").foregroundStyle(.secondary)
                } else {
                    ForEach(engine.agents.running) { agent in
                        LabeledContent {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(agent.isWorking ? Color.green : Color.secondary.opacity(0.4))
                                    .frame(width: 8, height: 8)
                                Text(agent.backgroundRuns > 0 ? "Background run" : (agent.isWorking ? "Working" : "Idle"))
                            }
                        } label: {
                            Text(agent.sessions > 1 ? "\(agent.kind.name) (\(agent.sessions) sessions)" : agent.kind.name)
                        }
                    }
                }
            }

            Section("Works with") {
                Text(AgentKind.all.map(\.name).joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: formWidth)
        .fixedSize()
    }
}

// MARK: - Safety

struct SafetySettingsView: View {
    @Bindable var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                Toggle("Turn off when the battery is low", isOn: $prefs.batteryGuard)
                Picker("Low means", selection: $prefs.batteryGuardPercent) {
                    ForEach([10, 15, 20, 30, 50], id: \.self) { percent in
                        Text("\(percent)% or less").tag(percent)
                    }
                }
                .disabled(!prefs.batteryGuard)
            } footer: {
                Text("Only counts when you're not plugged in.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Toggle("Turn off when the Mac gets hot", isOn: $prefs.heatGuard)
            } footer: {
                Text("With the lid closed it stops at the first warm level. A closed Mac in a bag can't cool itself down.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: formWidth)
        .fixedSize()
    }
}

// MARK: - About

struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
            VStack(spacing: 4) {
                Text("Double Shot").font(.title.weight(.semibold))
                Text("Version \(version)").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            Text("Keeps your Mac awake. With the lid closed too,\nand for as long as your AI agents are working.")
                .multilineTextAlignment(.center)
            VStack(spacing: 8) {
                Text("Made by Noah Elhadedy").font(.headline)
                HStack(spacing: 10) {
                    LinkButton(title: "noahelhadedy.com", url: Links.website)
                    LinkButton(title: "Source on GitHub", url: Links.repository)
                }
            }
            .padding(.top, 4)
            Text("Free and open source under the MIT License.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: formWidth)
        .fixedSize()
    }
}

private struct LinkButton: View {
    let title: String
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label(title, systemImage: "arrow.up.right")
                .labelStyle(TrailingIconLabelStyle())
        }
        .controlSize(.large)
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}
