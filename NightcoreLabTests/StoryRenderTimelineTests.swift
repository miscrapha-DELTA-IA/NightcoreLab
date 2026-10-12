import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import NightcoreLab

/// SwiftRender-style determinism: one immutable scene, integer frames and
/// source-time arithmetic shared by the preview and exported MP4.
final class StoryRenderTimelineTests: XCTestCase {
    private func request(_ mode: StoryMode = .lyrics,
                         start: TimeInterval = 9.5,
                         speed: Float = 1.25) throws -> StoryVideoRequest {
        let track = TrackInfo(
            track: Track(id: "12345678901", title: "A Sample - Demo",
                         thumbnailURL: nil, cleanArtist: "Demo"),
            fileName: nil, coverURL: nil)
        let words = [
            WordSync(id: 0, text: "SING", start: 10, end: 11, spaceAfter: true),
            WordSync(id: 1, text: "ALONG", start: 11, end: 13, spaceAfter: false)
        ]
        let line = TimedLyricLine(id: 0, start: 10, end: 13,
                                  words: words, precision: .word)
        return try StoryRequestBuilder.make(
            mode: mode, track: track, theme: .acid,
            playerStyle: .turbulent, karaokeBackground: .marble,
            marblePhase: 4.2, playbackTime: start, sourceDuration: 90,
            speed: speed, lines: [line], lyricOffset: 0.15,
            typography: .neon, includeAudio: false)
    }

    func testTimelineUsesExactIntegerFrameGridForVideoAndPreview() throws {
        let request = try request()
        let timeline = StoryRenderTimeline(request: request, profile: .balanced)
        XCTAssertEqual(timeline.frameCount, 300)
        let index = 47
        let video = timeline.frame(index: index)
        let preview = timeline.frame(at: Double(index) / 20)
        XCTAssertEqual(preview, video)
        XCTAssertEqual(video.elapsed, 2.35, accuracy: 0.000_001)
        XCTAssertEqual(video.sourceTime, 9.5 + 2.35 * 1.25, accuracy: 0.000_001)
        XCTAssertEqual(video.lyricTime, video.sourceTime + 0.15, accuracy: 0.000_001)
        XCTAssertEqual(video.marblePhase, 4.2 + Float(2.35) * 0.8,
                       accuracy: 0.000_1)
        XCTAssertEqual(timeline.frame(index: 500), timeline.frame(index: 299))
        XCTAssertEqual(timeline.frame(at: -.infinity), timeline.frame(index: 0))
        XCTAssertEqual(timeline.frame(at: .nan), timeline.frame(index: 0))
    }

    func testEconomicalAndBalancedProfilesDoNotDriftOverDuration() throws {
        let request = try request()
        for profile in [StoryEncodingProfile.economical, .balanced] {
            let timeline = StoryRenderTimeline(request: request, profile: profile)
            XCTAssertEqual(timeline.frameCount, profile.frameCount(duration: request.duration))
            XCTAssertLessThan(timeline.lastFrameElapsed, request.duration)
            for index in [0, 1, 3, timeline.frameCount / 2, timeline.lastFrameIndex] {
                let frame = timeline.frame(index: index)
                XCTAssertEqual(frame.elapsed, Double(index) / Double(profile.fps), accuracy: 1e-9)
                XCTAssertEqual(timeline.frame(at: frame.elapsed), frame)
            }
        }
    }

    func testNonIntegralClipDurationStopsOnLastValidFrame() throws {
        let clip = try request(.player, start: 88, speed: 1.25)
        let timeline = StoryRenderTimeline(request: clip, profile: .balanced)
        XCTAssertEqual(clip.duration, 1.6, accuracy: 0.00001)
        XCTAssertEqual(timeline.frameCount, 32)
        XCTAssertLessThanOrEqual(timeline.frame(index: 31).sourceTime, 90)
        XCTAssertEqual(timeline.frame(at: 400), timeline.frame(index: 31))
    }

    func testIdenticalFrameAlwaysHasIdenticalLyricAndMarbleState() throws {
        let request = try request(start: 9.5, speed: 1)
        let timeline = StoryRenderTimeline(request: request, profile: .balanced)
        let active = timeline.frame(index: 17)
        XCTAssertEqual(request.activeLine(at: active.elapsed)?.id, 0)
        let same = timeline.frame(at: active.elapsed)
        XCTAssertEqual(active, same)
        XCTAssertEqual(
            request.activeLine(at: same.elapsed)?.words.first?.progress(at: same.lyricTime),
            request.activeLine(at: active.elapsed)?.words.first?.progress(at: active.lyricTime)
        )
    }

    @MainActor
    func testExportFrameUsesSameVisualSceneAsScrubPreview() throws {
        let request = try request(.player)
        let profile = StoryEncodingProfile.economical
        let frame = StoryRenderTimeline(request: request, profile: profile).frame(index: 17)
        let encodedInput = try StoryFrameRenderer.render(
            request: request, artwork: nil, frame: frame, profile: profile)
        let previewScene = StorySceneView(request: request, artwork: nil, frame: frame)
        let renderer = ImageRenderer(content: previewScene)
        renderer.proposedSize = ProposedViewSize(StoryVideoRequest.size)
        renderer.scale = profile.scale
        let previewPixels = try XCTUnwrap(renderer.uiImage?.cgImage)
        XCTAssertEqual(encodedInput.width, profile.width)
        XCTAssertEqual(encodedInput.height, profile.height)
        XCTAssertEqual(previewPixels.width, encodedInput.width)
        XCTAssertEqual(previewPixels.height, encodedInput.height)
        XCTAssertLessThan(encodedInput.width, encodedInput.height,
                          "Story raster is portrait and must not be rotated")
    }
}
