import Foundation
import XCTest
@testable import NightcoreLab

/// Stage 12 (first cut): Marble material driven by RhythmFrame.
final class VisualMaterialTests: XCTestCase {
    /// 120 BPM from 1.0 s, downbeats on indices 0, 4, ...
    private func rhythm(confidence: Float = 0.9,
                        downbeatConfidence: Float = 0.7) -> RhythmAnalysisResult {
        let grid = (0..<16).map { index in
            RhythmAnalysisResult.BeatEvent(time: 1 + 0.5 * Double(index), index: index,
                                           strength: 1, isDownbeat: index % 4 == 0)
        }
        return RhythmAnalysisResult(onsetEvents: grid.map(\.time),
                                    bpmCandidates: [.init(bpm: 120, confidence: confidence)],
                                    beatGrid: grid, confidence: confidence,
                                    downbeatConfidence: downbeatConfidence)
    }

    private func program(_ reaction: CreativePreset.AudioReaction) -> CreativeVisualProgram {
        CreativePresetCatalog.effectiveProgram(
            id: "bass-pulse", theme: .acid, typography: .neon,
            background: .turbulent, reaction: reaction)
    }

    // MARK: Material derivation

    func testMaterialFollowsTheExistingReactionSwitch() {
        XCTAssertEqual(VisualMaterial.marble(for: nil), .legacyMarble)
        XCTAssertEqual(VisualMaterial.marble(for: program(.off)).beatPulse, 0)
        let responsive = VisualMaterial.marble(for: program(.responsive))
        let subtle = VisualMaterial.marble(for: program(.subtle))
        XCTAssertGreaterThan(responsive.beatPulse, subtle.beatPulse)
        XCTAssertGreaterThan(subtle.beatPulse, 0)
        XCTAssertLessThanOrEqual(responsive.beatPulse, 1)
    }

    func testMaterialIsBoundedAndCodable() throws {
        let wild = VisualMaterial(beatPulse: 7, pulseDecay: -3, offbeatScale: .nan)
        XCTAssertEqual(wild.beatPulse, 1)
        XCTAssertEqual(wild.pulseDecay, 1)
        XCTAssertEqual(wild.offbeatScale, 0.7)
        let material = VisualMaterial(beatPulse: 0.6, pulseDecay: 8, offbeatScale: 0.5)
        XCTAssertEqual(try JSONDecoder().decode(
            VisualMaterial.self, from: JSONEncoder().encode(material)), material)
    }

    // MARK: Uniforms

    func testPulseIsZeroWithoutReliableRhythm() {
        let material = VisualMaterial(beatPulse: 1)
        XCTAssertEqual(MaterialResolver.beatPulse(material, rhythm: nil), 0)
        let weak = RhythmFrame.at(1.0, in: rhythm(confidence: 0.2))
        XCTAssertEqual(MaterialResolver.beatPulse(material, rhythm: weak), 0)
        XCTAssertEqual(MaterialResolver.beatPulse(.legacyMarble,
                                                  rhythm: RhythmFrame.at(1.0, in: rhythm())), 0)
    }

    func testPulsePeaksOnTheBeatAccentsDownbeatsAndDecays() throws {
        let material = VisualMaterial(beatPulse: 1, pulseDecay: 6, offbeatScale: 0.7)
        let source = rhythm()
        let downbeat = MaterialResolver.beatPulse(material, rhythm: RhythmFrame.at(1.0, in: source))
        let offbeat = MaterialResolver.beatPulse(material, rhythm: RhythmFrame.at(1.5, in: source))
        let late = MaterialResolver.beatPulse(material, rhythm: RhythmFrame.at(1.4, in: source))
        XCTAssertEqual(downbeat, 1, accuracy: 1e-12)
        XCTAssertEqual(offbeat, 0.7, accuracy: 1e-12)
        XCTAssertLessThan(late, 0.05)
        // Unknown downbeats: every beat pulses fully.
        let flat = rhythm(downbeatConfidence: 0.1)
        XCTAssertEqual(MaterialResolver.beatPulse(material, rhythm: RhythmFrame.at(1.5, in: flat)),
                       1, accuracy: 1e-12)
    }

    func testMarbleUniformsCarryTheExistingDistortion() {
        let parameters = CreativeParameterFrame(playerGlow: 0, marbleDistortion: 0.42,
                                                lyricKinetics: 0, particleEmission: 0)
        let uniforms = MaterialResolver.marble(.legacyMarble, parameters: parameters, rhythm: nil)
        XCTAssertEqual(uniforms, MarbleUniforms(distortion: 0.42, beatPulse: 0))
    }

    // MARK: Story: same pulse at the same source time

    private func story(reactive: Bool, speed: Float = 1) throws -> StoryVideoRequest {
        let track = TrackInfo(track: Track(id: "12345678901", title: "Pulse",
                                           thumbnailURL: nil, cleanArtist: "Nightcore"),
                              fileName: nil, coverURL: nil)
        return try StoryRequestBuilder.make(
            mode: .player, track: track, theme: .acid,
            playerStyle: .turbulent, karaokeBackground: .marble,
            marblePhase: 1, playbackTime: 1, sourceDuration: 30,
            speed: speed, lines: [], lyricOffset: 0,
            typography: .classic, includeAudio: false,
            reactiveProgram: reactive ? program(.responsive) : nil,
            reactiveSourceURL: nil)
    }

    func testLegacyStoryHasNoPulse() throws {
        let request = try story(reactive: false)
        let frame = StoryRenderTimeline(request: request, profile: .balanced).frame(index: 0)
        let scene = StorySceneView(request: request, artwork: nil, frame: frame,
                                   visualRhythm: rhythm())
        XCTAssertEqual(scene.beatPulse, 0, "No reactive program: pre-Stage-12 Marble")
        let reactive = try story(reactive: true)
        let silent = StorySceneView(request: reactive, artwork: nil, frame: frame)
        XCTAssertEqual(silent.beatPulse, 0, "No rhythm analysis: no invented pulse")
    }

    func testStoryPulseIsAFunctionOfSourceTimeAcrossFrameRates() throws {
        let source = rhythm()
        let request = try story(reactive: true, speed: 1.25)
        let material = VisualMaterial.marble(for: request.reactiveProgram)
        for profile in [StoryEncodingProfile.balanced, .economical] {
            let grid = StoryRenderTimeline(request: request, profile: profile)
            for index in stride(from: 0, to: min(grid.frameCount, 120), by: 7) {
                let frame = grid.frame(index: index)
                let scene = StorySceneView(request: request, artwork: nil, frame: frame,
                                           visualRhythm: source)
                XCTAssertEqual(scene.beatPulse, MaterialResolver.beatPulse(
                    material, rhythm: RhythmFrame.at(frame.sourceTime, in: source)))
            }
        }
        // Preview (supplied composition frame) and export agree.
        let grid = StoryRenderTimeline(request: request, profile: .balanced)
        let frame = grid.frame(index: 13)
        let preview = StorySceneView(request: request, artwork: nil,
                                     frame: grid.frame(at: frame.elapsed),
                                     visualRhythm: source)
        let export = StorySceneView(request: request, artwork: nil, frame: frame,
                                    visualRhythm: source)
        XCTAssertEqual(preview.beatPulse, export.beatPulse)
    }

    // MARK: Live driver

    private final class FakeClock: PlaybackClock, @unchecked Sendable {
        var isPlaying = true
        var lyricTime: TimeInterval = 0
    }

    func testLiveDriverMatchesTheResolverAtTheClockTime() {
        let clock = FakeClock()
        let material = VisualMaterial(beatPulse: 0.8)
        let source = rhythm()
        let driver = MarblePulseDriver(material: material, rhythm: source, clock: clock)
        for time in stride(from: 0.9, to: 4.0, by: 0.13) {
            clock.lyricTime = time
            XCTAssertEqual(driver.pulse(), MaterialResolver.beatPulse(
                material, rhythm: RhythmFrame.at(time, in: source)))
        }
        clock.isPlaying = false
        clock.lyricTime = 1.0
        XCTAssertEqual(driver.pulse(), 0, "Paused: no pulse")
        XCTAssertEqual(driver, driver)
        XCTAssertNotEqual(driver, MarblePulseDriver(material: material, rhythm: source, clock: clock))
    }

    @MainActor
    func testLiveUniformsHidePulseWhileFrozen() {
        let uniforms = CreativeLiveUniforms()
        let driver = MarblePulseDriver(material: VisualMaterial(beatPulse: 1),
                                       rhythm: rhythm(), clock: FakeClock())
        uniforms.setPulseDriver(driver)
        XCTAssertEqual(uniforms.livePulseDriver, driver)
        uniforms.freeze()
        XCTAssertNil(uniforms.livePulseDriver)
        uniforms.unfreeze()
        XCTAssertEqual(uniforms.livePulseDriver, driver)
        uniforms.setPulseDriver(nil)
        XCTAssertNil(uniforms.livePulseDriver)
    }
}
