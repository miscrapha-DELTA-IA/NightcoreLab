import Foundation

/// A SwiftRender-inspired, deterministic scene clock. Rendering is a pure
/// function of the immutable StoryVideoRequest and integer presentation frame.
/// The same frame is used by the preview, still captures and MP4 encoder.
struct StoryRenderFrame: Equatable, Sendable {
    let index: Int
    let elapsed: TimeInterval
    let sourceTime: TimeInterval
    let lyricTime: TimeInterval
    let marblePhase: Float
}

/// Media time uses the original source clock (already includes playback speed).
/// The frame grid is frozen with the export profile at the moment the draft
/// is opened; Low Power Mode cannot change it halfway through a render.
struct StoryRenderTimeline: Sendable {
    let request: StoryVideoRequest
    let profile: StoryEncodingProfile

    var frameCount: Int { profile.frameCount(duration: request.duration) }
    var lastFrameIndex: Int { frameCount - 1 }
    var lastFrameElapsed: TimeInterval {
        Double(lastFrameIndex) / Double(profile.fps)
    }

    func frame(index: Int) -> StoryRenderFrame {
        let clamped = min(max(index, 0), lastFrameIndex)
        let seconds = Double(clamped) / Double(profile.fps)
        return StoryRenderFrame(index: clamped, elapsed: seconds,
                                sourceTime: request.sourceTime(at: seconds),
                                lyricTime: request.lyricTime(at: seconds),
                                marblePhase: request.marbleTime(at: seconds))
    }

    /// Preview scrubbing snaps to the exact same frame grid as the encoder.
    func frame(at elapsed: TimeInterval) -> StoryRenderFrame {
        guard elapsed.isFinite else { return frame(index: 0) }
        let bounded = min(max(elapsed, 0), lastFrameElapsed)
        return frame(index: Int((bounded * Double(profile.fps)).rounded()))
    }
}
