import SwiftUI

/// Deterministic, low-frequency motion. No state, timers, random numbers,
/// audio callbacks or heavy per-frame allocations are involved.
struct TurbulentMotion: Equatable {
    let horizontal: Double
    let vertical: Double
    let scale: Double

    static func sample(at seconds: TimeInterval, blob index: Int) -> TurbulentMotion {
        let phase = Double(index) * 1.71
        // Incommensurate waves keep the paths organic without a Metal shader.
        let horizontal = 0.105 * sin(seconds * (0.115 + Double(index) * 0.021) + phase)
            + 0.035 * cos(seconds * 0.053 + phase * 0.7)
        let vertical = 0.082 * cos(seconds * (0.089 + Double(index) * 0.016) + phase)
            + 0.028 * sin(seconds * 0.047 - phase)
        let scale = 1.0 + 0.085 * sin(seconds * (0.069 + Double(index) * 0.011) + phase * 1.3)
        return TurbulentMotion(horizontal: horizontal, vertical: vertical, scale: scale)
    }
}

enum TurbulentPalette {
    static func colors(for theme: AppTheme) -> [Color] {
        switch theme {
        case .acid:
            return [
                Color(red: 0.20, green: 1.00, blue: 0.03), // neon green
                Color(red: 0.96, green: 0.87, blue: 0.08), // acid yellow
                Color(red: 0.02, green: 0.29, blue: 0.12), // deep green
                Color(red: 0.10, green: 0.63, blue: 0.19)
            ]
        case .cyber:
            return [
                Color(red: 0.00, green: 0.84, blue: 1.00), // cyan
                Color(red: 0.93, green: 0.09, blue: 0.66), // magenta
                Color(red: 0.39, green: 0.17, blue: 0.85), // purple
                Color(red: 0.06, green: 0.19, blue: 0.55)
            ]
        case .crimson:
            return [
                Color(red: 0.90, green: 0.06, blue: 0.15), // blood red
                Color(red: 0.74, green: 0.23, blue: 0.04), // deep orange
                Color(red: 0.23, green: 0.01, blue: 0.07), // almost-black maroon
                Color(red: 0.55, green: 0.04, blue: 0.13)
            ]
        }
    }
}

private struct TurbulentBlob: View {
    let index: Int
    let color: Color
    let time: TimeInterval
    let size: CGSize

    private static let anchors: [UnitPoint] = [
        UnitPoint(x: 0.19, y: 0.16),
        UnitPoint(x: 0.81, y: 0.36),
        UnitPoint(x: 0.28, y: 0.80),
        UnitPoint(x: 0.82, y: 0.91)
    ]

    var body: some View {
        let motion = TurbulentMotion.sample(at: time, blob: index)
        let anchor = Self.anchors[index]
        let diameter = max(size.width, size.height) * (index.isMultiple(of: 2) ? 0.84 : 0.69)

        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(0.73), color.opacity(0.38), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter * 0.5
                )
            )
            .frame(width: diameter, height: diameter)
            .scaleEffect(CGFloat(motion.scale))
            .position(
                x: size.width * (anchor.x + CGFloat(motion.horizontal)),
                y: size.height * (anchor.y + CGFloat(motion.vertical))
            )
            .blendMode(.screen)
    }
}

/// Fluid light on OLED-black, with just four blurred native SwiftUI circles.
/// Place behind the player content; the full opacity can be controlled by the
/// caller (the player defaults to 0.6).
struct TurbulentBackgroundView: View {
    let theme: AppTheme
    var blurRadius: CGFloat = 80

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var animates: Bool { !reduceMotion && scenePhase == .active }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !animates)) { context in
            // Fixed arrangement for Reduce Motion / offscreen scenes.
            let time = animates ? context.date.timeIntervalSinceReferenceDate : 0.0
            let palette = TurbulentPalette.colors(for: theme)
            GeometryReader { geometry in
                ZStack {
                    Color(red: 0.008, green: 0.009, blue: 0.014)

                    ZStack {
                        ForEach(0..<4, id: \.self) { index in
                            TurbulentBlob(
                                index: index,
                                color: palette[index],
                                time: time,
                                size: geometry.size
                            )
                        }
                    }
                    .compositingGroup()
                    .blur(radius: blurRadius, opaque: false)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
        }
        .animation(.easeInOut(duration: 0.65), value: theme)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
