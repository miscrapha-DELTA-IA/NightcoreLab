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
        case .ultraviolet:
            return [
                Color(red: 0.45, green: 0.41, blue: 0.94),
                Color(red: 0.70, green: 0.25, blue: 0.85),
                Color(red: 0.62, green: 0.65, blue: 0.82),
                Color(red: 0.10, green: 0.08, blue: 0.38)
            ]
        case .solar:
            return [
                Color(red: 1.00, green: 0.78, blue: 0.15),
                Color(red: 0.98, green: 0.52, blue: 0.18),
                Color(red: 0.60, green: 0.24, blue: 0.98),
                Color(red: 0.25, green: 0.08, blue: 0.45)
            ]
        case .orchid:
            return [
                Color(red: 0.55, green: 0.20, blue: 0.58),
                Color(red: 0.80, green: 0.45, blue: 0.85),
                Color(red: 0.70, green: 0.68, blue: 0.76),
                Color(red: 0.20, green: 0.04, blue: 0.24)
            ]
        case .sapphire:
            return [
                Color(red: 0.12, green: 0.25, blue: 0.84),
                Color(red: 0.45, green: 0.52, blue: 0.92),
                Color(red: 0.60, green: 0.66, blue: 0.90),
                Color(red: 0.03, green: 0.07, blue: 0.38)
            ]
        case .atomic:
            return [
                Color(red: 0.05, green: 0.58, blue: 0.58),
                Color(red: 0.92, green: 0.24, blue: 0.14),
                Color(red: 0.85, green: 0.80, blue: 0.68),
                Color(red: 0.02, green: 0.20, blue: 0.22)
            ]
        case .lagoon:
            return [
                Color(red: 0.05, green: 0.42, blue: 0.66),
                Color(red: 1.00, green: 0.76, blue: 0.15),
                Color(red: 0.12, green: 0.58, blue: 0.82),
                Color(red: 0.02, green: 0.18, blue: 0.38)
            ]
        case .volt:
            return [
                Color(red: 0.95, green: 0.85, blue: 0.02),
                Color(red: 0.65, green: 0.66, blue: 0.72),
                Color(red: 0.80, green: 0.70, blue: 0.00),
                Color(red: 0.30, green: 0.27, blue: 0.00)
            ]
        case .prism:
            return [
                Color(red: 0.38, green: 0.30, blue: 0.66),
                Color(red: 0.98, green: 0.52, blue: 0.10),
                Color(red: 0.10, green: 0.70, blue: 0.95),
                Color(red: 0.98, green: 0.76, blue: 0.05)
            ]
        case .magma:
            return [
                Color(red: 0.05, green: 0.17, blue: 0.52),
                Color(red: 1.00, green: 0.45, blue: 0.06),
                Color(red: 0.78, green: 0.80, blue: 0.92),
                Color(red: 0.02, green: 0.05, blue: 0.25)
            ]
        case .noir:
            return [
                Color(red: 0.85, green: 0.04, blue: 0.06),
                Color(red: 0.80, green: 0.80, blue: 0.84),
                Color(red: 0.35, green: 0.00, blue: 0.03),
                Color(red: 0.40, green: 0.40, blue: 0.44)
            ]
        case .ultrapink:
            return [
                Color(red: 1.00, green: 0.08, blue: 0.58), // hot pink
                Color(red: 1.00, green: 0.55, blue: 0.82), // light pink
                Color(red: 0.55, green: 0.00, blue: 0.35), // deep magenta
                Color(red: 0.30, green: 0.00, blue: 0.20)
            ]
        case .ultraorange:
            return [
                Color(red: 0.98, green: 0.27, blue: 0.08), // neon orange
                Color(red: 0.85, green: 0.90, blue: 0.97), // ice white
                Color(red: 0.45, green: 0.08, blue: 0.02), // dark red
                Color(red: 0.60, green: 0.66, blue: 0.78)
            ]
        case .purewhite:
            return [
                Color(red: 0.80, green: 0.82, blue: 0.86), // silver
                Color(red: 0.95, green: 0.96, blue: 0.98), // white
                Color(red: 0.45, green: 0.47, blue: 0.52), // grey
                Color(red: 0.12, green: 0.12, blue: 0.15)
            ]
        case .ultrablack:
            return [
                Color(red: 0.10, green: 0.10, blue: 0.12),
                Color(red: 0.18, green: 0.19, blue: 0.23),
                Color(red: 0.05, green: 0.05, blue: 0.07),
                Color(red: 0.28, green: 0.29, blue: 0.34)
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

    private var animates: Bool {
        !reduceMotion && scenePhase == .active
    }
    private var motionInterval: Double {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? 1.0 / 12.0 : 1.0 / 20.0
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: motionInterval, paused: !animates)) { context in
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
