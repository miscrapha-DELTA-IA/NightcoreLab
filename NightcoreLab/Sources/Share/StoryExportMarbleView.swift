import SwiftUI

/// Export-only time-deterministic silky marble. ImageRenderer rasterizes native
/// gradients, not a live TimelineView/CADisplayLink or GPU shader history.
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
            let phase = Double(StoryExportMotion.phase(
                at: renderTimestamp, start: startingPhase, speed: steadyFlowSpeed))
            ZStack {
                LinearGradient(colors: [palette.deep, palette.body.opacity(0.55),
                                        palette.deep, palette.glow.opacity(0.45)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                ForEach(0..<3, id: \.self) { i in
                    let shift = Double(i) * 2.1
                    Ellipse()
                        .fill(AngularGradient(colors: [
                            palette.deep.opacity(0.2), palette.body,
                            palette.glow.opacity(0.75), palette.deep.opacity(0.3)
                        ], center: .center))
                        .frame(width: size.width * CGFloat(1.05 + Double(i) * 0.3),
                               height: size.height * 0.66)
                        .rotationEffect(.radians(phase * (i.isMultiple(of: 2) ? 0.16 : -0.13) + shift))
                        .offset(x: CGFloat(sin(phase * 0.62 + shift)) * size.width * 0.24,
                                y: CGFloat(cos(phase * 0.43 + shift)) * size.height * 0.22)
                        .blur(radius: min(size.width, size.height) * 0.08)
                        .blendMode(.screen)
                }
                // Never reassign phase/geometry when a beat arrives.
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
}
