import Foundation

/// Opt-in typography input attached to a matching .typography PresetLayer.
/// The clock offset is applied to ORIGINAL source seconds, never to video elapsed.
struct TypographyLayer: Sendable {
    let layerID: String
    let state: LyricsState
    let preset: TypographyPreset
    let lyricOffset: TimeInterval
    /// Optional precomputed seeds/looks for `state.line` (Stage 10C cache).
    /// Purely an optimization: the resolved frame is identical without it.
    let prepared: TypographyPreparedLine?
    /// Stage 12.5: the selected experience's audio envelope, applied per
    /// frame through `TypographyPreset.modulated` (disabled = no change).
    let experienceMapping: CreativeAudioMapping

    init(layerID: String = "typography", state: LyricsState,
         preset: TypographyPreset, lyricOffset: TimeInterval = 0,
         prepared: TypographyPreparedLine? = nil,
         experienceMapping: CreativeAudioMapping = .disabled) {
        self.layerID = layerID
        self.state = state
        self.preset = preset
        self.lyricOffset = lyricOffset
        self.prepared = prepared
        self.experienceMapping = experienceMapping
    }

    /// The Story's active line with the preset frozen in its request. There
    /// is deliberately no default preset: a missing one used to mean Neon.
    static func forStory(lines: [TimedLyricLine],
                         lyricTime: TimeInterval,
                         lyricOffset: TimeInterval,
                         preset: TypographyPreset,
                         prepared: [Int: TypographyPreparedLine] = [:],
                         experienceMapping: CreativeAudioMapping = .disabled) -> TypographyLayer? {
        guard let line = lines.last(where: { $0.start <= lyricTime && lyricTime < $0.end })
        else { return nil }
        return TypographyLayer(
            state: LyricsState(line: line, status: .active),
            preset: preset,
            lyricOffset: lyricOffset,
            prepared: prepared[line.id],
            experienceMapping: experienceMapping)
    }

    /// Single resolution entry point for this layer, shared by
    /// CompositionRuntime and the Story path without a reactive composition.
    func resolve(at lyricTime: TimeInterval,
                 features: AudioFeatures?) -> TypographyFrame {
        TypographyResolver.resolve(
            state, at: lyricTime, features: features,
            preset: preset.modulated(by: experienceMapping, features: features),
            prepared: prepared)
    }
}
