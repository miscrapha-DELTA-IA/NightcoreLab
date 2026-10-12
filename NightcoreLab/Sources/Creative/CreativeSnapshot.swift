import Foundation

/// Optional future handoff for the existing ShareRenderer/StoryVideoExporter.
/// This model does not replace ShareSnapshot, StoryVideoRequest or app state.
struct CreativeSnapshot: Equatable, Sendable {
    struct VisualState: Equatable, Sendable {
        let playbackTime: TimeInterval
        let marblePhase: Float
        let isPlaying: Bool

        init(playbackTime: TimeInterval = 0, marblePhase: Float = 0,
             isPlaying: Bool = false) {
            self.playbackTime = playbackTime.isFinite ? max(0, playbackTime) : 0
            self.marblePhase = marblePhase.isFinite ? max(0, marblePhase) : 0
            self.isPlaying = isPlaying
        }
    }

    let track: Track?
    let theme: AppTheme
    let preset: CreativePreset
    let visualState: VisualState
    let capturedAt: Date

    /// Captures current *values* only. No AVAudioEngine, SwiftUI or UserDefaults
    /// dependency, and no effect is activated when this function is called.
    static func capture(track: Track?, theme: AppTheme,
                        typographyStyle: KaraokeTypographyStyle,
                        playerBackground: PlayerBackgroundStyle,
                        playbackTime: TimeInterval,
                        marblePhase: Float,
                        isPlaying: Bool,
                        capturedAt: Date = .now) -> CreativeSnapshot {
        let preset = CreativePreset.current(
            theme: theme, typographyStyle: typographyStyle,
            playerBackground: playerBackground
        )
        return CreativeSnapshot(
            track: track, theme: theme, preset: preset,
            visualState: VisualState(playbackTime: playbackTime,
                                     marblePhase: marblePhase,
                                     isPlaying: isPlaying),
            capturedAt: capturedAt
        )
    }
}
