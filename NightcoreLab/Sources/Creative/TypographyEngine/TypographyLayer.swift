import Foundation

/// Opt-in typography input attached to a matching .typography PresetLayer.
/// The clock offset is applied to ORIGINAL source seconds, never to video elapsed.
struct TypographyLayer: Sendable {
    let layerID: String
    let state: LyricsState
    let preset: TypographyPreset
    let lyricOffset: TimeInterval

    init(layerID: String = "typography", state: LyricsState,
         preset: TypographyPreset, lyricOffset: TimeInterval = 0) {
        self.layerID = layerID
        self.state = state
        self.preset = preset
        self.lyricOffset = lyricOffset
    }

    static func forStory(lines: [TimedLyricLine],
                         lyricTime: TimeInterval,
                         lyricOffset: TimeInterval,
                         preset: TypographyPreset = TypographyPreset(style: .neon)) -> TypographyLayer? {
        guard let line = lines.last(where: { $0.start <= lyricTime && lyricTime < $0.end })
        else { return nil }
        return TypographyLayer(
            state: LyricsState(line: line, status: .active),
            preset: preset,
            lyricOffset: lyricOffset)
    }
}
