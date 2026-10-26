import SwiftUI

/// What opens from the menu bar cup.
struct PanelView: View {
    let engine: AwakeEngine
    var openSettings: (SettingsTab) -> Void
    var quit: () -> Void
    @Bindable private var prefs = Preferences.shared

    /// Pour stops, bottom to top. -1 = until turned off, 0 = off.
    private static let stops = [0, 15, 30, 60, 120, 180, 300, 480, -1]
    @State private var pourIndex: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            hero
            chips
            if let cutoff = engine.lastCutoff, !engine.isAwake {
                CutoffBanner(cutoff: cutoff)
            }
            modes
            footer
        }
        .padding(12)
        .frame(width: 340)
        .focusEffectDisabled()
    }

    // MARK: - Hero

    private var hero: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 14) {
                EspressoGlass(level: glassLevel, isSteaming: engine.isHeldForAgents && pourIndex == nil,
                              pourLabel: pourLabel, isAnimated: !reduceMotion)
                    .frame(width: 104, height: Self.glassHeight)
                    .contentShape(Rectangle())
                    .gesture(pourGesture)
                    .onTapGesture { engine.toggle() }
                    .help("Drag up to pour time, click to switch")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Time left")
                    .accessibilityValue("\(bigTitle == "∞" ? "Until you turn it off" : bigTitle). \(sentence)")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { engine.toggle() }
                    .accessibilityAdjustableAction { direction in step(direction == .increment ? 1 : -1) }

                VStack(alignment: .leading, spacing: 6) {
                    Group {
                        if bigTitle == "∞" {
                            Image(systemName: "infinity").font(.system(size: 34, weight: .bold))
                                .accessibilityLabel("Until you turn it off")
                        } else {
                            Text(bigTitle).font(.system(size: 38, weight: .bold, design: .rounded))
                        }
                    }
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(Theme.cream)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(sentence)
                        .font(.callout)
                        .foregroundStyle(Theme.cream.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                    if engine.isLidHeld {
                        Label("Safe to close the lid", systemImage: "laptopcomputer")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.crema)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.crema.opacity(0.15), in: Capsule())
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.green, Theme.greenDeep], startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.08))
            )
        }
    }

    private var glassLevel: Double {
        if let pourIndex { return Double(pourIndex) / Double(Self.stops.count - 1) }
        if engine.isManualOn, let end = engine.manualEnd, engine.manualMinutes > 0 {
            return max(end.timeIntervalSinceNow, 0) / Double(engine.manualMinutes * 60) * 0.92
        }
        return engine.isAwake ? 0.92 : 0
    }

    private var pourLabel: String? {
        guard let pourIndex else { return nil }
        return Self.label(for: Self.stops[pourIndex])
    }

    private static let glassHeight: CGFloat = 150
    /// The part of the glass that holds coffee, measured from the top of the glass view
    /// (EspressoGlass draws the glass in the lower 72% and keeps 13% of that for the base).
    private static let liquidTop = glassHeight * 0.28
    private static let liquidBottom = glassHeight - glassHeight * 0.72 * 0.13

    /// Keyboard and VoiceOver: one pour stop up or down from where it is now.
    private func step(_ delta: Int) {
        let current = engine.isManualOn ? (Self.stops.firstIndex(of: engine.manualEnd == nil ? -1 : engine.manualMinutes) ?? 0) : 0
        let next = min(max(current + delta, 0), Self.stops.count - 1)
        let minutes = Self.stops[next]
        if minutes == 0 { engine.turnOff() } else { engine.turnOn(minutes: max(minutes, 0)) }
    }

    private var pourGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                // The higher the pointer over the coffee, the fuller the shot
                let span = Self.liquidBottom - Self.liquidTop
                let fraction = 1 - min(max((value.location.y - Self.liquidTop) / span, 0), 1)
                let index = Int((fraction * Double(Self.stops.count - 1)).rounded())
                if index != pourIndex {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    pourIndex = index
                }
            }
            .onEnded { _ in
                guard let index = pourIndex else { return }
                let minutes = Self.stops[index]
                if minutes == 0 { engine.turnOff() } else { engine.turnOn(minutes: max(minutes, 0)) }
                withAnimation(.easeOut(duration: 0.2)) { pourIndex = nil }
            }
    }

    private var bigTitle: String {
        if let pourIndex { return Self.label(for: Self.stops[pourIndex]) }
        if engine.isManualOn {
            guard let end = engine.manualEnd else { return "∞" }
            return Self.clock(end.timeIntervalSinceNow)
        }
        if engine.isHeldForAgents { return "Brewing" }
        return "Off"
    }

    private var sentence: String {
        if pourIndex != nil { return "Let go to pour." }
        let working = engine.agents.running.filter(\.isWorking).map(\.kind.name)
        if engine.isManualOn {
            if !working.isEmpty { return "\(Self.names(working)) working too." }
            return engine.manualEnd == nil ? "Awake until you say stop." : "Then your Mac sleeps like normal."
        }
        if engine.isHeldForAgents {
            if engine.agents.running.contains(where: { $0.backgroundRuns > 0 }) {
                return "A background run is going. I'll stay up until it's done."
            }
            if working.isEmpty { return "Your agents just finished. Letting go in a few minutes." }
            return "\(Self.names(working)) working. I'll stay up until it's done."
        }
        if engine.isAgentHoldSuppressed { return "Paused until your agents finish." }
        if prefs.agentMode { return "Sleeps like normal, and wakes up by itself when an agent starts working." }
        return "Your Mac sleeps like normal. Drag up on the glass to pour some time."
    }

    /// "Claude Code is" or "Claude Code and Codex are".
    static func names(_ names: [String]) -> String {
        "\(ListFormatter.localizedString(byJoining: names)) \(names.count == 1 ? "is" : "are")"
    }

    static func label(for minutes: Int) -> String {
        switch minutes {
        case 0: "Off"
        case -1: "∞"
        case ..<60: "\(minutes)m"
        default: "\(minutes / 60)h"
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded(.up)), 0)
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    // MARK: - Quick picks

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach([15, 30, 60, 120, 300, 0], id: \.self) { minutes in
                let selected = engine.isManualOn && engine.manualMinutes == minutes
                Button(minutes == 0 ? "∞" : Self.label(for: minutes)) {
                    selected ? engine.turnOff() : engine.turnOn(minutes: minutes)
                }
                .buttonStyle(ChipButtonStyle(isSelected: selected))
                .accessibilityLabel(minutes == 0 ? "Until you turn it off" : StatusItemController.durations.first { $0.minutes == minutes }?.title ?? "")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    // MARK: - Modes

    private var lidOn: Bool {
        engine.isLidSetUp && prefs.lidClosed
    }

    private var modes: some View {
        VStack(alignment: .leading, spacing: 14) {
            if SystemState.hasLid {
                ModeRow(symbol: "laptopcomputer", title: "Lid closed", detail: lidDetail, isOn: lidOn) {
                    if engine.isLidSetUp {
                        Toggle("Lid closed", isOn: $prefs.lidClosed)
                            .accessibilityHint(lidDetail)
                    } else {
                        Button("Set up") { openSettings(.lid) }
                            .controlSize(.small)
                    }
                }
            }
            ModeRow(symbol: "sparkles", title: "AI agents", detail: agentDetail, isOn: prefs.agentMode) {
                Toggle("AI agents", isOn: $prefs.agentMode)
                    .accessibilityHint(agentDetail)
            }
            if prefs.agentMode, !engine.agents.running.isEmpty {
                AgentsList(agents: engine.agents.running)
                    .padding(.leading, 42)
            }
        }
        .toggleStyle(.switch)
        .labelsHidden()
        .tint(Theme.crema)
        .padding(12)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var lidDetail: String {
        guard engine.isLidSetUp else { return "Needs your password once." }
        return lidOn ? "Close the lid and the work keeps going." : "Closing the lid puts your Mac to sleep."
    }

    /// What agents mode is doing right now, in one plain line.
    private var agentDetail: String {
        guard prefs.agentMode else { return "Off. Agents won't keep your Mac awake." }
        let running = engine.agents.running
        guard !running.isEmpty else { return "None open. I'll stay up by myself once one starts working." }
        if engine.isAgentHoldSuppressed { return "Paused by you until they finish." }
        if let cutoff = engine.lastCutoff, !engine.isAwake {
            return cutoff == .heat ? "Stopped because your Mac got warm." : "Stopped because the battery is low."
        }
        let lidPart = lidOn ? ", lid closed too." : "."
        let background = running.reduce(0) { $0 + $1.backgroundRuns }
        if background > 0 {
            return (background == 1 ? "A background run is going" : "\(background) background runs are going")
                + ". Staying up until done" + lidPart
        }
        let working = running.filter(\.isWorking).map(\.kind.name)
        if !working.isEmpty {
            return "\(Self.names(working)) working. Staying up" + lidPart
        }
        if engine.isHeldForAgents { return "Just finished. Letting go in a few minutes." }
        let sessions = running.reduce(0) { $0 + $1.sessions }
        return sessions == 1 ? "Open but idle, so your Mac can sleep." : "\(sessions) open, all idle, so your Mac can sleep."
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button { openSettings(.general) } label: { Label("Settings", systemImage: "gearshape") }
            Spacer()
            if engine.isLidHeld {
                // Apple menu > Sleep does nothing while the lid hold is on
                Button { engine.sleepNow() } label: { Label("Sleep Now", systemImage: "moon") }
            }
            Button("Quit", action: quit)
        }
        .buttonStyle(QuietButtonStyle())
        .labelStyle(.titleAndIcon)
    }
}

// MARK: - Pieces

private struct ModeRow<Control: View>: View {
    let symbol: String
    let title: String
    let detail: String
    let isOn: Bool
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isOn ? Theme.greenDeep : .secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(isOn ? AnyShapeStyle(Theme.crema) : AnyShapeStyle(.primary.opacity(0.08))))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: detail)
            }
            Spacer(minLength: 8)
            control
        }
    }
}

private struct AgentsList: View {
    let agents: [AgentMonitor.Status]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(agents) { agent in
                HStack(spacing: 8) {
                    PulseDot(isActive: agent.isWorking)
                    Text(agent.kind.name).font(.callout.weight(.medium))
                    if agent.sessions > 1 {
                        Text("×\(agent.sessions)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(agent.backgroundRuns > 0 ? "Background run" : (agent.isWorking ? "Working" : "Idle"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(agent.backgroundRuns > 0 ? Theme.cremaInk : (agent.isWorking ? Color.green : .secondary))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PulseDot: View {
    let isActive: Bool
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(isActive ? Color.green : Color.secondary.opacity(0.5))
            .frame(width: 7, height: 7)
            .background(
                Circle()
                    .fill(Color.green.opacity(isActive ? 0.35 : 0))
                    .scaleEffect(pulse ? 2.6 : 1)
                    .opacity(pulse ? 0 : 1)
            )
            .onAppear(perform: restart)
            .onChange(of: isActive) { restart() }
    }

    private func restart() {
        pulse = false
        guard isActive, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
    }
}

private struct CutoffBanner: View {
    let cutoff: AwakeEngine.Cutoff

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: cutoff == .heat ? "thermometer.high" : "battery.25")
                .foregroundStyle(.orange)
            Text(cutoff == .heat ? "Your Mac got too warm, so I let it rest." : "Battery got low, so I let it sleep.")
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
