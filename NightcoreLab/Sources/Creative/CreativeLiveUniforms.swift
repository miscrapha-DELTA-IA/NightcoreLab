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
    /// Stage 12: render-rate beat pulse source for the live Marble material.
    /// Changes only when the analyzed source or program changes.
    private(set) var pulseDriver: MarblePulseDriver?

    var marbleDistortion: Double {
        frozenDistortion ?? frame.marbleDistortion
    }

    /// Writes only on change, so equal frames never invalidate readers.
    func update(_ next: CreativeParameterFrame) {
        if frame != next { frame = next }
    }

    func setPulseDriver(_ driver: MarblePulseDriver?) {
        if pulseDriver != driver { pulseDriver = driver }
    }

    /// A frozen (sharing) Marble shows no live pulse.
    var livePulseDriver: MarblePulseDriver? {
        frozenDistortion == nil ? pulseDriver : nil
    }

    func freeze() { frozenDistortion = frame.marbleDistortion }

    func unfreeze() { frozenDistortion = nil }
}

/// Leaf reader: the only place where the live distortion and the pulse
/// driver are observed.
struct LiveMarbleDistortion<Content: View>: View {
    let uniforms: CreativeLiveUniforms
    @ViewBuilder let content: (Double, MarblePulseDriver?) -> Content

    var body: some View {
        content(uniforms.marbleDistortion, uniforms.livePulseDriver)
    }
}
