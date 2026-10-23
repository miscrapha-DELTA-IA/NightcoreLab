import Foundation
import SwiftUI

/// One deterministic formation timeline shared by the player and Story.
/// The actual bitmap comes from the existing artwork cache/Story artwork.
/// This is not an album-hue approximation or another image decoder.
enum XeroxArtworkReveal {
    static func progress(at sourceTime: TimeInterval,
                         duration: TimeInterval) -> Double {
        guard sourceTime.isFinite, sourceTime > 0 else { return 0 }
        let revealLength: Double = duration.isFinite && duration > 0
            ? max(8, duration * 0.20) : 24
        let x = min(1, max(0, sourceTime / revealLength))
        return x * x * (3 - 2 * x)
    }

    /// Fixed, offline deterministic dither schedule. Monotonic in progress,
    /// independent of app launch, CPU hash seed, display FPS and export order.
    static func threshold(column: Int, row: Int) -> Double {
        var x = UInt64(max(0, column) &* 73_931 + max(0, row) &* 19_397 + 0x2a4b)
        x = (x ^ (x >> 16)) &* 0x7feb352d
        x = (x ^ (x >> 15)) &* 0x846ca68b
        x = x ^ (x >> 16)
        return Double(x & 0xffff) / 65535 * 0.87
    }

    static func cellFill(progress: Double, column: Int, row: Int) -> Double {
        let threshold = Self.threshold(column: column, row: row)
        return min(1, max(0, (progress - threshold) * 7.8))
    }
}

/// The SAME lightweight SwiftUI composition works over the live Metal scene
/// and the offscreen Story Metal frame. Both display pixels from the *actual*
/// cached album cover, progressively exposing them as toner halftone cells.
/// No network, GPU readback, CA timer or second audio analysis pipeline.
struct XeroxArtworkFormationView: View {
    let image: Image
    let sourceTime: TimeInterval
    let duration: TimeInterval
    var bass: Double = 0

    private var progress: Double {
        XeroxArtworkReveal.progress(at: sourceTime, duration: duration)
    }

    var body: some View {
        GeometryReader { viewport in
            let edge = min(viewport.size.width * 0.78, viewport.size.height * 0.52)
            let exposed = progress
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black.opacity(0.47))
                    .overlay {
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(.white.opacity(0.17), lineWidth: 1)
                    }

                image.resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: edge, height: edge)
                    .clipped()
                    .saturation(0.18 + 0.48 * exposed)
                    .contrast(1.15 + 0.35 * exposed)
                    .mask {
                        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                            let columns = 20
                            let rows = 20
                            let w = size.width / CGFloat(columns)
                            let h = size.height / CGFloat(rows)
                            for row in 0..<rows {
                                for col in 0..<columns {
                                    let strength = XeroxArtworkReveal.cellFill(
                                        progress: exposed, column: col, row: row)
                                    guard strength > 0 else { continue }
                                    let scale = CGFloat(0.12 + 0.88 * strength)
                                    let rect = CGRect(
                                        x: (CGFloat(col) + (1 - scale) / 2) * w,
                                        y: (CGFloat(row) + (1 - scale) / 2) * h,
                                        width: w * scale + (strength >= 0.99 ? 0.5 : 0),
                                        height: h * scale + (strength >= 0.99 ? 0.5 : 0))
                                    context.fill(Path(ellipseIn: rect),
                                                 with: .color(.white))
                                    if strength >= 0.94 {
                                        // Join fully exposed cells into the
                                        // original cover, not permanent dots.
                                        context.fill(Path(CGRect(
                                            x: CGFloat(col) * w, y: CGFloat(row) * h,
                                            width: w + 0.5, height: h + 0.5)),
                                                     with: .color(.white))
                                    }
                                }
                            }
                        }
                    }
                    .accessibilityHidden(true)

                // Scanning head creates graphic mechanical motion without
                // drifting the actual artwork image or coupling to wall time.
                if exposed > 0.01 && exposed < 0.99 {
                    Rectangle()
                        .fill(Color.white.opacity(0.11 + min(0.20, max(0, bass) * 0.17)))
                        .frame(height: max(2, edge * 0.009))
                        .offset(y: (CGFloat(exposed) - 0.5) * edge)
                        .blendMode(.screen)
                }
            }
            .frame(width: edge, height: edge)
            .position(x: viewport.size.width / 2,
                      y: viewport.size.height / 2)
            .accessibilityIdentifier("xerox.realArtworkReveal")
        }
        .allowsHitTesting(false)
    }
}
