import AppKit
import SwiftUI

/// Colors taken from the app icon: coffee shop green and crema.
enum Theme {
    static let green = Color(red: 0.16, green: 0.29, blue: 0.25)
    static let greenDeep = Color(red: 0.11, green: 0.21, blue: 0.18)
    static let crema = Color(red: 0.86, green: 0.62, blue: 0.38)
    static let cream = Color(red: 0.97, green: 0.93, blue: 0.86)
    /// Crema for text: darker in light mode so it stays readable on light backgrounds.
    static let cremaInk = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.86, green: 0.62, blue: 0.38, alpha: 1)
            : NSColor(red: 0.55, green: 0.33, blue: 0.12, alpha: 1)
    })
}

/// A rounded square with a white symbol, like the rows in System Settings.
struct IconBadge: View {
    let symbol: String
    var tint: Color = Theme.green
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

/// A row with a badge, a title, an optional line under it and a trailing control.
struct BadgeRow<Trailing: View>: View {
    let symbol: String
    var tint: Color = Theme.green
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

/// Small rounded button used for the duration chips.
struct ChipButtonStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 28)
            .foregroundStyle(isSelected ? Theme.greenDeep : .primary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Theme.crema) : AnyShapeStyle(.primary.opacity(configuration.isPressed ? 0.14 : 0.07)))
            )
            .contentShape(Rectangle())
    }
}

/// Text button that only shows a background on hover, for the panel footer.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietButton(configuration: configuration)
    }

    private struct QuietButton: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.primary.opacity(isHovered || configuration.isPressed ? 0.08 : 0))
                )
                .onHover { isHovered = $0 }
        }
    }
}
