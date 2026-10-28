import SwiftUI

/// First run: a few short steps that ask for everything the app needs, one at a time.
struct WelcomeView: View {
    let engine: AwakeEngine
    /// Called when the person is done. `openPanel` is true when they asked to see the panel.
    var finish: (_ openPanel: Bool) -> Void
    @Bindable private var prefs = Preferences.shared

    enum Step: String, CaseIterable {
        case hello, login, lid, agents, done
    }

    private var steps: [Step] {
        Step.allCases.filter { $0 != .lid || SystemState.hasLid }
    }

    @State var step: Step = .hello
    @State private var loginState = LoginItem.isEnabled
    @State private var loginMessage: String?
    @State private var lidMessage: String?
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .padding(.horizontal, 36)
                .padding(.top, 26)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .frame(width: 560, height: 470)
        .background(.background)
    }

    // MARK: - Header

    private var header: some View {
        ZStack(alignment: .bottom) {
            // The green runs up under the transparent title bar
            LinearGradient(colors: [Theme.green, Theme.greenDeep], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 84, height: 84)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                HStack(spacing: 6) {
                    ForEach(steps, id: \.self) { item in
                        Capsule()
                            .fill(item == step ? Theme.crema : Theme.cream.opacity(0.25))
                            .frame(width: item == step ? 22 : 7, height: 7)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: step)
                .accessibilityElement()
                .accessibilityLabel("Step \((steps.firstIndex(of: step) ?? 0) + 1) of \(steps.count)")
            }
            .padding(.bottom, 20)
        }
        .frame(height: 170)
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .hello:
            StepText(title: "Meet Double Shot",
                     text: "It keeps your Mac awake when you need it: for a while, with the lid closed, and for as long as your AI agents are working.\n\nA few quick steps and you're set.")
        case .login:
            VStack(alignment: .leading, spacing: 18) {
                StepText(title: "Open at login",
                         text: "So Double Shot is there every time you start your Mac. You can change this later in Settings.")
                if loginState {
                    DoneLabel(text: "Opens at login")
                } else {
                    Button("Open at Login") {
                        loginMessage = LoginItem.set(true)
                        loginState = LoginItem.isEnabled
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.green)
                    .controlSize(.large)
                    if let loginMessage {
                        HStack {
                            Text(loginMessage).foregroundStyle(.secondary)
                            if LoginItem.needsApproval {
                                Button("Open Login Items") { LoginItem.openSystemSettings() }
                            }
                        }
                    }
                }
            }
        case .lid:
            VStack(alignment: .leading, spacing: 18) {
                StepText(title: "Keep working with the lid closed",
                         text: "macOS always sleeps when you close the lid. Double Shot can stop that, so you can close your Mac and the work keeps going.\n\nIt needs your password once. It only gets permission to switch sleep and Low Power Mode on and off, nothing else.")
                if engine.isLidSetUp {
                    DoneLabel(text: "Lid closed mode is ready")
                } else {
                    HStack(spacing: 12) {
                        Button("Allow Lid Closed Mode…", action: allowLid)
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.green)
                            .controlSize(.large)
                            .disabled(isWorking)
                        if isWorking { ProgressView().controlSize(.small) }
                    }
                    if let lidMessage {
                        Label(lidMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
        case .agents:
            VStack(alignment: .leading, spacing: 18) {
                StepText(title: "Stay awake for AI agents",
                         text: "When Claude Code, Codex or another agent is working, your Mac stays awake by itself\(engine.isLidSetUp ? ", lid closed too" : ""). Sessions that are just open and waiting don't count.")
                Toggle("Stay awake while AI agents work", isOn: $prefs.agentMode)
                    .toggleStyle(.switch)
                    .tint(Theme.crema)
                Text(agentsLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .done:
            VStack(alignment: .leading, spacing: 18) {
                StepText(title: "You're all set",
                         text: "Double Shot lives in your menu bar. Click the mug to open it, then drag up on the glass to pour some time, or let your agents keep it going.")
                MenuBarHint()
            }
        }
    }

    private var agentsLine: String {
        guard prefs.agentMode else { return "Off. You can turn it on any time from the panel." }
        let running = engine.agents.running
        guard !running.isEmpty else { return "No agents open right now. It starts by itself when one does." }
        let names = running.map { $0.sessions > 1 ? "\($0.kind.name) (\($0.sessions) open)" : $0.kind.name }
        return "Right now: \(ListFormatter.localizedString(byJoining: names))."
    }

    private func allowLid() {
        isWorking = true
        lidMessage = nil
        Task { @MainActor in
            // Let the spinner show before the password dialog takes over
            try? await Task.sleep(for: .milliseconds(50))
            switch LidHold.install() {
            case .done: prefs.lidClosed = true
            case .cancelled: break
            case .failed(let reason): lidMessage = reason
            }
            engine.refreshLidSetup()
            isWorking = false
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step != steps.first {
                Button("Back") { move(-1) }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if step == .done {
                Button("Open the Panel") { finish(true) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.green)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(continueTitle) { move(1) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.green)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    /// "Not now" when the step's ask is still open, so skipping is a clear choice.
    private var continueTitle: String {
        switch step {
        case .hello: "Get Started"
        case .login: loginState ? "Continue" : "Not Now"
        case .lid: engine.isLidSetUp ? "Continue" : "Not Now"
        default: "Continue"
        }
    }

    private func move(_ delta: Int) {
        guard let index = steps.firstIndex(of: step) else { return }
        let next = min(max(index + delta, 0), steps.count - 1)
        withAnimation(.easeInOut(duration: 0.2)) { step = steps[next] }
    }
}

// MARK: - Pieces

private struct StepText: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title2.weight(.semibold))
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct DoneLabel: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.headline)
            .foregroundStyle(.green)
    }
}

/// A little menu bar with the mug highlighted, so people know where to look.
private struct MenuBarHint: View {
    var body: some View {
        HStack(spacing: 18) {
            Spacer()
            Image(systemName: "mug.fill")
                .font(.system(size: 15, weight: .medium))
                .padding(6)
                .background(Theme.crema.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Image(systemName: "wifi")
            Image(systemName: "battery.100")
            Text("Mon 9:41").font(.callout.weight(.medium))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }
}
