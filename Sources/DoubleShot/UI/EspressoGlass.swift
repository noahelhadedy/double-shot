import SwiftUI

/// The hero of the panel: a shot glass whose espresso level is the time left.
/// Drag up on it to pour a duration, tap it to switch on or off. It steams while agents work.
struct EspressoGlass: View {
    /// 0 empty ... 1 full.
    var level: Double
    var isSteaming: Bool
    /// Shown inside the glass while pouring.
    var pourLabel: String?
    /// Off with Reduce Motion: the coffee sits still and the steam stays put.
    var isAnimated = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isAnimated || (level <= 0.001 && !isSteaming))) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                draw(in: &canvas, size: size, time: time)
            }
        }
        .overlay {
            if let pourLabel {
                Text(pourLabel)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.cream)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.35), in: Capsule())
                    .offset(y: 22)
                    .transition(.opacity)
            }
        }
    }

    // Glass geometry, relative to the canvas: steam on top, glass below
    private func glassRect(_ size: CGSize) -> CGRect {
        let width = size.width * 0.78
        let height = size.height * 0.72
        return CGRect(x: (size.width - width) / 2, y: size.height - height, width: width, height: height)
    }

    private func tumbler(in rect: CGRect, inset: CGFloat = 0) -> Path {
        let taper = rect.width * 0.11
        let radius = rect.width * 0.12
        let r = rect.insetBy(dx: inset, dy: inset)
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - taper, y: r.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: r.maxX - taper - radius, y: r.maxY), control: CGPoint(x: r.maxX - taper, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + taper + radius, y: r.maxY))
        path.addQuadCurve(to: CGPoint(x: r.minX + taper, y: r.maxY - radius), control: CGPoint(x: r.minX + taper, y: r.maxY))
        path.closeSubpath()
        return path
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let glass = glassRect(size)
        let base = glass.height * 0.13
        let inner = CGRect(x: glass.minX, y: glass.minY, width: glass.width, height: glass.height - base)
        let innerPath = tumbler(in: inner, inset: 5)

        // Soft shadow under the glass
        canvas.fill(Path(ellipseIn: CGRect(x: glass.midX - glass.width * 0.36, y: glass.maxY - 5, width: glass.width * 0.72, height: 9)),
                    with: .color(.black.opacity(0.25)))

        // Espresso, with a moving crema surface
        let clamped = min(max(level, 0), 1)
        if clamped > 0.001 {
            var liquidContext = canvas
            liquidContext.clip(to: innerPath)
            let fillTop = inner.maxY - (inner.height - 5) * clamped
            let wave = wavePath(in: inner, top: fillTop, time: time)
            liquidContext.fill(wave, with: .linearGradient(
                Gradient(colors: [Color(red: 0.36, green: 0.21, blue: 0.11), Color(red: 0.16, green: 0.08, blue: 0.04)]),
                startPoint: CGPoint(x: 0, y: fillTop), endPoint: CGPoint(x: 0, y: inner.maxY)))
            // Crema band on top
            var crema = liquidContext
            crema.clip(to: wave)
            crema.fill(Path(CGRect(x: inner.minX, y: fillTop - 6, width: inner.width, height: 14)),
                       with: .linearGradient(Gradient(colors: [Theme.crema, Theme.crema.opacity(0)]),
                                             startPoint: CGPoint(x: 0, y: fillTop), endPoint: CGPoint(x: 0, y: fillTop + 12)))
        }

        // Glass walls and solid base
        let outer = tumbler(in: glass)
        canvas.stroke(outer, with: .color(.white.opacity(0.55)), lineWidth: 2.5)
        let baseRect = CGRect(x: glass.minX + glass.width * 0.13, y: glass.maxY - base, width: glass.width * 0.74, height: base - 3)
        canvas.fill(Path(roundedRect: baseRect, cornerRadius: 6), with: .color(.white.opacity(0.14)))
        // Highlight along the left wall
        var shine = Path()
        shine.move(to: CGPoint(x: glass.minX + glass.width * 0.1, y: glass.minY + 10))
        shine.addLine(to: CGPoint(x: glass.minX + glass.width * 0.18, y: glass.maxY - base - 10))
        canvas.stroke(shine, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 3, lineCap: .round))

        if isSteaming {
            drawSteam(in: &canvas, above: glass, time: time)
        }
    }

    private func wavePath(in rect: CGRect, top: CGFloat, time: TimeInterval) -> Path {
        var path = Path()
        let amplitude: CGFloat = 2.2
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        var x = rect.minX
        while x <= rect.maxX {
            let progress = (x - rect.minX) / rect.width
            let y = top + sin(progress * .pi * 2.2 + time * 2.4) * amplitude
            path.addLine(to: CGPoint(x: x, y: y))
            x += 2
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    private func drawSteam(in canvas: inout GraphicsContext, above glass: CGRect, time: TimeInterval) {
        for index in 0..<2 {
            let phase = time * 0.9 + Double(index) * 1.7
            let cycle = phase.truncatingRemainder(dividingBy: 2.4) / 2.4 // 0...1 rising
            let startX = glass.midX + (index == 0 ? -9 : 9)
            let bottom = glass.minY - 4 - cycle * 10
            let height = glass.minY * 0.85
            var path = Path()
            path.move(to: CGPoint(x: startX, y: bottom))
            var y: CGFloat = 0
            while y <= height {
                let progress = y / height
                let x = startX + sin(progress * .pi * 2 + phase * 2 + Double(index) * .pi) * 6 * progress
                path.addLine(to: CGPoint(x: x, y: bottom - y))
                y += 2
            }
            let opacity = sin(cycle * .pi) * 0.7
            canvas.stroke(path, with: .linearGradient(
                Gradient(colors: [Theme.cream.opacity(opacity), Theme.cream.opacity(0)]),
                startPoint: CGPoint(x: 0, y: bottom), endPoint: CGPoint(x: 0, y: bottom - height)),
                style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
        }
    }
}
