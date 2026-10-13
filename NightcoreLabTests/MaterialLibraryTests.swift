import Foundation
import XCTest
@testable import NightcoreLab

/// Stage 13B, complementary to VisualMaterialEngineTests (Stage 13).
final class MaterialLibraryTests: XCTestCase {
    private let features = AudioFeatures(
        bass: 0.72, mid: 0.3, treble: 0.81, energy: 0.64, beatDetected: true)
    private let parameters = CreativeParameterFrame(
        playerGlow: 0.4, marbleDistortion: 0.38,
        lyricKinetics: 0.45, particleEmission: 0)

    func testEverySupportedMaterialProducesAFrame() {
        for material in VisualMaterialCatalog.all {
            let frame = MaterialResolver.resolve(material,
                features: features, timestamp: 2.125, parameters: parameters, seed: 31337)
            XCTAssertEqual(frame.materialID, material.id)
            XCTAssertEqual(frame.type, material.type)
            XCTAssertEqual(frame.controls, material.controls)
            XCTAssertEqual(frame.seed, 31337)
            XCTAssertEqual(frame.timestamp, 2.125)
            XCTAssertTrue(frame.parameters.distortion.isFinite)
        }
    }

    func testDeterminismAcrossSeekOrderAndFrames() {
        for material in VisualMaterialCatalog.all {
            func resolve(_ time: Double) -> MaterialFrame {
                MaterialResolver.resolve(material, features: features,
                    timestamp: time, parameters: parameters, seed: 0xC1B5)
            }
            let reference = resolve(4.25)
            _ = resolve(1); _ = resolve(9); _ = resolve(0.1)
            XCTAssertEqual(resolve(4.25), reference)
            XCTAssertNotEqual(resolve(4.375).timestamp, reference.timestamp)
            XCTAssertNotEqual(MaterialResolver.resolve(material, features: features,
                timestamp: 4.25, parameters: parameters, seed: 0xC1B6), reference)
        }
    }

    func testAudioSignalsAreWhitelistedAndBounded() {
        let glass = MaterialResolver.resolve(VisualMaterialCatalog.glassSurface,
            features: features, timestamp: 1, parameters: parameters)
        XCTAssertEqual(glass.signals.energy, features.energy)
        XCTAssertEqual(glass.signals.bass, 0)
        let chrome = MaterialResolver.resolve(VisualMaterialCatalog.chromeNight,
            features: features, timestamp: 1, parameters: parameters)
        XCTAssertEqual(chrome.signals.brightness, features.treble)
        XCTAssertEqual(chrome.signals.energy, features.energy)
        let organic = MaterialResolver.resolve(VisualMaterialCatalog.organicPulse,
            features: features, timestamp: 1, parameters: parameters)
        XCTAssertEqual(organic.signals.bass, features.bass)
        // Movement comes from the material mapping only, never the program.
        let mapping = VisualMaterialCatalog.organicPulse.audioMapping
        XCTAssertEqual(organic.signals.movement,
                       min(1, features.energy * mapping.energyToMovement), accuracy: 1e-12)
        let otherKinetics = MaterialResolver.resolve(VisualMaterialCatalog.organicPulse,
            features: features, timestamp: 1,
            parameters: CreativeParameterFrame(playerGlow: 0.4, marbleDistortion: 0.9,
                                               lyricKinetics: 0.05, particleEmission: 0))
        XCTAssertEqual(otherKinetics.signals, organic.signals)
        XCTAssertEqual(otherKinetics.parameters, organic.parameters,
                       "Program parameters never reach an authored material")
        XCTAssertEqual(organic.signals.energy, 0)
        for kind in VisualMaterialType.allCases {
            let signals = kind.acceptedSignals
            XCTAssertEqual(Set(signals).count, signals.count)
        }
    }

    func testControlsAreClampedAndOldJSONStillDecodes() throws {
        let clamped = MaterialControls(.nan, -2, 4, .infinity)
        XCTAssertEqual(clamped, MaterialControls(0, 0, 1, 0))
        let old = Data(#"{"kind":"marble","beatPulse":0.6}"#.utf8)
        let legacy = try JSONDecoder().decode(VisualMaterial.self, from: old)
        XCTAssertEqual(legacy, VisualMaterial(beatPulse: 0.6))
        for material in VisualMaterialCatalog.all {
            let data = try JSONEncoder().encode(material)
            XCTAssertEqual(try JSONDecoder().decode(VisualMaterial.self, from: data), material)
            if var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                json.removeValue(forKey: "controls")
                let restored = try JSONDecoder().decode(VisualMaterial.self,
                    from: JSONSerialization.data(withJSONObject: json))
                XCTAssertEqual(restored.controls, MaterialControls.defaults(for: material.type))
            }
        }
    }

    func testNewExperienceMaterialsAreAuthoritative() throws {
        let expected: [(String, VisualMaterialType)] = [
            ("liquid-dream", .liquidGlass),
            ("chrome-night", .chrome),
            ("organic-pulse", .organicNoise),
            ("cyber-marble", .advancedMarble),
            ("atmospheric-smoke", .atmosphericSmoke)]
        for (id, type) in expected {
            let experience = try XCTUnwrap(CreativePresetCatalog.selectedExperience(id: id))
            XCTAssertEqual(experience.visualMaterial.type, type)
            XCTAssertEqual(CreativePresetCatalog.recipe(for: id).id, id)
            XCTAssertEqual(try JSONDecoder().decode(CreativeExperiencePreset.self,
                from: JSONEncoder().encode(experience)), experience)
        }
        XCTAssertEqual(CreativePresetCatalog.experience(for: "original")?.visualMaterial.type,
                       .marble)
    }

    func testStage13LegacyMarbleNotChanged() {
        let legacy = VisualMaterial.legacyMarble
        let output = MaterialResolver.resolve(legacy, features: features,
            timestamp: 2, parameters: parameters)
        XCTAssertEqual(output.type, .marble)
        XCTAssertEqual(output.marbleUniforms, MaterialResolver.marble(
            legacy, parameters: parameters, rhythm: nil))
        XCTAssertEqual(output.controls, .defaults(for: .marble))
    }

    func testPreviewExportParityForAllNewPresets() throws {
        let track = TrackInfo(track: Track(id: "12345678901", title: "Library",
            thumbnailURL: nil, cleanArtist: "NightcoreLab"),
            fileName: nil, coverURL: nil)
        let timeline = AudioFeatureTimeline(points: [
            .init(time: 0, features: features), .init(time: 30, features: features)
        ], duration: 30)
        for id in ["liquid-dream", "chrome-night", "organic-pulse",
                   "cyber-marble", "atmospheric-smoke"] {
            let program = CreativePresetCatalog.effectiveProgram(
                id: id, theme: .cyber, typography: .neon,
                background: .turbulent, reaction: .responsive)
            let request = try StoryRequestBuilder.make(
                mode: .player, track: track, theme: .cyber,
                playerStyle: .turbulent, karaokeBackground: .marble,
                marblePhase: 1, playbackTime: 3, sourceDuration: 30,
                speed: 1.25, lines: [], lyricOffset: 0,
                typography: .classic, includeAudio: false,
                reactiveProgram: program, creativePresetID: id)
            let runtime = try XCTUnwrap(request.compositionRuntime)
            for profile in [StoryEncodingProfile.balanced, .economical] {
                let grid = StoryRenderTimeline(request: request, profile: profile)
                for index in [0, 11, 30] {
                    let frame = grid.frame(index: index)
                    let supplied = runtime.frame(at: frame.elapsed, audioTimeline: timeline)
                    let preview = StorySceneView(request: request, artwork: nil, frame: frame,
                        visualTimeline: timeline, resolvedCompositionFrame: supplied)
                    let exported = StorySceneView(request: request, artwork: nil,
                        frame: frame, visualTimeline: timeline)
                    XCTAssertEqual(preview.materialFrame, exported.materialFrame)
                    XCTAssertEqual(exported.materialFrame.type,
                        try XCTUnwrap(CreativePresetCatalog.selectedExperience(id: id)).visualMaterial.type)
                }
            }
        }
    }
}
