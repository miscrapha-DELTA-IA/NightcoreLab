import Observation
import SwiftUI

/// Live, ~12 Hz creative parameters for the visible player.
///
/// Stage 10C: these values used to live in `@State` on `NowPlayingScreen`,
/// so every reactive update re-evaluated the whole screen body. As an
/// `@Observable` reference, only the leaf views that READ `marbleDistortion`
/// (through `LiveMarbleDistortion`) are invalidated. The parent only holds
/// the reference and never reads its properties in `body`.
@MainActor
@Observable
final class CreativeLiveUniforms {
    private(set) var frame: CreativeParameterFrame = .neutral
    /// While sharing, the visible Marble is frozen at the captured value.
    private(set) var frozenDistortion: Double?

    var marbleDistortion: Double {
        frozenDistortion ?? frame.marbleDistortion
    }

    /// Writes only on change, so equal frames never invalidate readers.
    func update(_ next: CreativeParameterFrame) {
        if frame != next { frame = next }
    }

    func freeze() { frozenDistortion = frame.marbleDistortion }

    func unfreeze() { frozenDistortion = nil }
}

/// Leaf reader: the only place where the live distortion is observed.
struct LiveMarbleDistortion<Content: View>: View {
    let uniforms: CreativeLiveUniforms
    @ViewBuilder let content: (Double) -> Content

    var body: some View {
        content(uniforms.marbleDistortion)
    }
}
