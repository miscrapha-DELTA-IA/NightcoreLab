import SwiftUI

/// Export-only time-deterministic silky marble. ImageRenderer rasterizes native
/// gradients, with no live frame scheduler or GPU shader history.
struct StoryExportMarbleView: View {
    let theme: AppTheme
    let renderTimestamp: TimeInterval
    let steadyFlowSpeed: Float
    let startingPhase: Float
    let materialFrame: MaterialFrame

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let palette = MarbleTheme(appTheme: theme).palette
            let authored = VisualMaterialCatalog.curatedPalettes[materialFrame.materialID]?
                .hex.map { Self.authoredColor($0) }
            let deep = authored?.first ?? palette.deep
            let body = (authored?.count ?? 0) > 1 ? authored![1] : palette.body
            let accent = (authored?.count ?? 0) > 2 ? authored![2] : palette.glow
            let settings = materialFrame.parameters
            let smoke = materialFrame.type == .atmosphericSmoke
            let phase = Double(StoryExportMotion.phase(
                at: renderTimestamp, start: startingPhase, speed: steadyFlowSpeed))
            ZStack {
                LinearGradient(colors: [deep, body.opacity(0.58),
                                        deep, palette.glow.opacity(0.45)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                ForEach(0..<3, id: \.self) { i in
                    let shift = Double(i) * 2.1
                    Ellipse()
                        .fill(AngularGradient(colors: [
                            deep.opacity(0.2), body, accent.opacity(0.75),
                            palette.glow.opacity(0.55), deep.opacity(0.3)
                        ], center: .center))
                        .frame(width: size.width * CGFloat(
                                   1.05 + Double(i) * 0.3 + settings.combStretch * 0.025),
                               height: size.height * CGFloat(smoke ? 0.88 : 0.66))
                        .rotationEffect(.radians(
                            phase * (i.isMultiple(of: 2) ? 0.16 : -0.13) + shift))
                        .offset(x: CGFloat(sin(phase * 0.62 + shift)) * size.width * 0.24,
                                y: CGFloat(cos(phase * 0.43 + shift)) * size.height * 0.22)
                        .blur(radius: min(size.width, size.height) *
                              CGFloat((smoke ? 0.15 : 0.08) +
                                      settings.diffusionSoftness * 0.05))
                        .blendMode(.screen)
                }
                // ⚡ color stays visible even for authored multi-stop materials.
                // Beats never reassign phase or geometric displacement.
                palette.glow.opacity(materialFrame.parameters.beatPulse * 0.12
                    + materialFrame.signals.brightness * 0.10)
                    .blendMode(.screen)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
    private static func authoredColor(_ hex: String) -> Color {
        let clean = hex.replacingOccurrences(of: "#", with: "")
        let value = UInt32(clean, radix: 16) ?? 0
        return Color(
            red: Double((value >> 16) & 255) / 255,
            green: Double((value >> 8) & 255) / 255,
            blue: Double(value & 255) / 255)
    }

}
