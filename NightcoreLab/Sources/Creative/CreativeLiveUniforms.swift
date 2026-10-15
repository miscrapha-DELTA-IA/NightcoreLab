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
    /// Stage 12.5: the reacting run's frozen feature envelope, so the live
    /// karaoke samples the SAME features a Story samples at a source time
    /// (CompositionAudioSampler). Nil while visuals do not react.
    private(set) var featureTimeline: AudioFeatureTimeline?
    /// Immutable track intelligence, changed only after asynchronous cache
    /// resolution; renders never open cache files or wait for actors.
    private(set) var songDNA: SongDNA?
    private(set) var sectionCadence: SongSectionCadence = .neutral

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

    /// Set once per reacting run and cleared when it ends.
    func setFeatureTimeline(_ timeline: AudioFeatureTimeline?) {
        if timeline == nil, featureTimeline == nil { return }
        featureTimeline = timeline
    }

    func setSongDNA(_ value: SongDNA?) {
        songDNA = value
        setSectionCadence(.neutral)
    }

    /// Section changes at <= 10 Hz, never at shader frame rate.
    func setSectionCadence(_ value: SongSectionCadence) {
        if sectionCadence != value { sectionCadence = value }
    }

    /// Features for the live karaoke at a source time; nil without reaction.
    func typographyFeatures(at sourceTime: TimeInterval) -> AudioFeatures? {
        CompositionAudioSampler.sample(featureTimeline, at: sourceTime)
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
    @ViewBuilder let content: (Double, MarblePulseDriver?, SongSectionCadence) -> Content

    var body: some View {
        content(uniforms.marbleDistortion, uniforms.livePulseDriver,
                uniforms.sectionCadence)
    }
}
