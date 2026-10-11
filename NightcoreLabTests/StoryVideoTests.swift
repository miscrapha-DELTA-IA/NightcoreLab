import XCTest
import SwiftUI
@testable import NightcoreLab

final class StoryVideoTests: XCTestCase {
    private func track() -> TrackInfo {
        TrackInfo(track: Track(id: "12345678901", title: "Demo · Artist",
                               thumbnailURL: nil, cleanArtist: "Artist"),
                  fileName: nil, coverURL: nil)
    }

    private func line() -> TimedLyricLine {
        TimedLyricLine(id: 0, start: 5, end: 8, words: [
            WordSync(id: 0, text: "Hello", start: 5, end: 6, spaceAfter: true),
            WordSync(id: 1, text: "world", start: 6, end: 8, spaceAfter: false)
        ], precision: .word)
    }

    private func request(mode: StoryMode, start: TimeInterval = 4,
                         total: TimeInterval = 120,
                         speed: Float = 1, hasLyrics: Bool = true) throws -> StoryVideoRequest {
        try StoryRequestBuilder.make(
            mode: mode, track: track(), theme: .acid,
            playerStyle: .turbulent, karaokeBackground: .marble,
            marblePhase: 2.3, playbackTime: start, sourceDuration: total,
            speed: speed, lines: hasLyrics ? [line()] : [],
            lyricOffset: 0.2, typography: .classic, includeAudio: false)
    }

    func testStoryFramesUseOriginalAudioTimeAndDeterministicShaderPhase() throws {
        let clip = try request(mode: .lyrics, speed: 1.25)
        XCTAssertEqual(clip.duration, 15, accuracy: 0.00001)
        XCTAssertEqual(clip.frameCount, 450)
        XCTAssertEqual(clip.sourceTime(at: 10), 16.5, accuracy: 0.00001)
        XCTAssertEqual(clip.lyricTime(at: 10), 16.7, accuracy: 0.00001)
        XCTAssertEqual(clip.marbleTime(at: 2), 3.9, accuracy: 0.001)
    }

    func testStoryClampsToEndInsteadOfLoopingSound() throws {
        let clip = try request(mode: .player, start: 98, total: 100, speed: 1.25)
        XCTAssertEqual(clip.duration, 1.6, accuracy: 0.0001)
        XCTAssertEqual(clip.frameCount, 48)
        XCTAssertEqual(clip.sourceTime(at: clip.duration), 100, accuracy: 0.0001)
    }

    func testUnavailableLyricsDisablesLyricStoryButNotPlayerStory() throws {
        XCTAssertThrowsError(try request(mode: .lyrics, hasLyrics: false))
        let player = try request(mode: .player, hasLyrics: false)
        XCTAssertFalse(player.canExportLyrics)
        XCTAssertEqual(player.duration, 15)
    }

    func testWordProgressAtArbitraryFrameIsNotGuessed() throws {
        let clip = try request(mode: .lyrics, start: 4.5)
        let active = try XCTUnwrap(clip.activeLine(at: 1))
        XCTAssertEqual(active.words.first?.progress(at: clip.lyricTime(at: 1)) ?? -1,
                       0.7, accuracy: 0.0001)
        XCTAssertNil(clip.activeLine(at: 8))
    }

    func testEveryTypographyHasStableIdentifier() {
        XCTAssertEqual(Set(StoryLyricTypography.allCases.map(\.id)).count,
                       StoryLyricTypography.allCases.count)
    }

    @MainActor
    func testSingleStoryFrameRendersWithoutNetwork() throws {
        let clip = try request(mode: .player)
        let renderer = ImageRenderer(content: StorySceneView(
            request: clip, artwork: nil, elapsed: 1.0))
        renderer.proposedSize = ProposedViewSize(StoryVideoRequest.size)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertEqual(image.size.width * image.scale, 1080, accuracy: 1)
        XCTAssertEqual(image.size.height * image.scale, 1920, accuracy: 1)
    }
}
