import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import NightcoreLab

final class VisualMaterialEngineTests: XCTestCase {
    private let features = AudioFeatures(bass: 0.8, mid: 0.4, treble: 0.2,
                                          energy: 0.7, beatDetected: true)
    private func rhythm(phase: Double = 0.2, barBeat: Int = 0,
                        confidence: Float = 0.9) -> RhythmFrame {
        RhythmFrame(beatIndex: barBeat, phase: phase, timeSinceBeat: phase * 0.5,
                    bpm: 120, beatStrength: 1, barBeat: barBeat,
                    barPhase: (Double(barBeat) + phase) / 4,
                    confidence: confidence, downbeatConfidence: 0.8)
    }

    private func timeline() -> AudioFeatureTimeline {
        AudioFeatureTimeline(points: [
            .init(time: 0, features: features), .init(time: 20, features: features)
        ], duration: 20)
    }

    private func program(_ id: String, _ reaction: CreativePreset.AudioReaction = .responsive)
        -> CreativeVisualProgram {
        CreativePresetCatalog.effectiveProgram(id: id, theme: .acid, typography: .neon,
                                               background: .turbulent, reaction: reaction)
    }

    /// Independent Stage 12.5 formula: must not delegate to the new resolver.
    private func legacyPulse(_ material: VisualMaterial, _ frame: RhythmFrame?) -> Double {
        guard material.beatPulse > 0, let frame else { return 0 }
        let trust = min(1, max(0, (Double(frame.confidence) - 0.25) / 0.5))
        guard trust > 0 else { return 0 }
        let accent = frame.barBeat != nil && frame.downbeatConfidence >= 0.3 &&
            frame.barBeat != 0 ? material.offbeatScale : 1
        return min(1, max(0, material.beatPulse * trust * accent * frame.pulse(decay: material.pulseDecay)))
    }

    func testMaterialDeterminismAcrossSeeksAndFrameRates() {
        for material in VisualMaterialCatalog.all {
            let expected = MaterialResolver.resolve(material, features: features,
                                                    rhythm: rhythm(), timestamp: 3.25)
            for time in [7.0, 0, 1.5, 3.25, 3.25] {
                _ = MaterialResolver.resolve(material, features: .silent, timestamp: time)
            }
            XCTAssertEqual(expected, MaterialResolver.resolve(
                material, features: features, rhythm: rhythm(), timestamp: 3.25))
            XCTAssertEqual(expected.timestamp, 3.25)
        }
    }

    func testMarbleMatchesIndependentLegacyUniformsExactly() {
        for recipe in CreativePresetCatalog.all {
            for reaction in [CreativePreset.AudioReaction.off, .subtle, .responsive] {
                let program = program(recipe.id, reaction)
                let material = VisualMaterial.marble(for: program)
                for time in [0.0, 0.13, 2.5, 9.25, 19.9] {
                    let old = CreativeMarbleFrameResolver.resolve(
                        program: program, timeline: timeline(), sourceTime: time)
                    for phase in [0.0, 0.1, 0.5, 0.99] {
                        for beat in 0..<4 {
                            let rhythm = rhythm(phase: phase, barBeat: beat)
                            let expected = MarbleUniforms(
                                distortion: old.marbleDistortion,
                                beatPulse: legacyPulse(material, rhythm))
                            let actual = MaterialResolver.resolve(
                                material, features: features, rhythm: rhythm,
                                timestamp: time, parameters: old)
                            XCTAssertEqual(actual.marbleUniforms, expected)
                        }
                    }
                }
            }
        }
    }

    func testAudioRoutesAreIndependentBoundedAndCanBeDisabled() {
        let material = VisualMaterial(id: "extreme", name: "Extreme",
            parameters: .init(beatPulse: 1, warpAmount: 8, brightnessBoost: 8),
            audioMapping: .init(bassToDistortion: 8, energyToBrightness: 8,
                                beatToPulse: 8, downbeatToAccent: 8))
        let output = MaterialResolver.resolve(material, features: features,
                                               rhythm: rhythm(phase: 0), timestamp: 2)
        XCTAssertEqual(output.parameters.warpAmount, 0.5)
        XCTAssertEqual(output.parameters.brightnessBoost, 0.3)
        XCTAssertEqual(output.audioResponse.distortion, 0.8)
        XCTAssertEqual(output.audioResponse.brightness, 0.21, accuracy: 1e-12)
        XCTAssertEqual(output.audioResponse.accent, 0.3)
        XCTAssertEqual(output.audioResponse.pulse, 1)
        let off = MaterialResolver.resolve(material, features: features,
                                            rhythm: rhythm(), timestamp: 2, reactionGain: 0)
        XCTAssertEqual(off.audioResponse, .init(distortion: 0, brightness: 0, pulse: 0, accent: 0))
        let noRhythm = MaterialResolver.resolve(material, features: features, timestamp: 2)
        XCTAssertEqual(noRhythm.audioResponse.pulse, 0)
        XCTAssertEqual(noRhythm.audioResponse.accent, 0)
        XCTAssertGreaterThan(noRhythm.audioResponse.distortion, 0)
        XCTAssertEqual(MaterialResolver.resolve(material, rhythm: rhythm(confidence: 0.1),
                                                timestamp: 2).audioResponse.pulse, 0)
        for time in [Double.nan, .infinity, -1] {
            let invalid = MaterialResolver.resolve(material, features: features,
                                                     rhythm: rhythm(), timestamp: time)
            XCTAssertEqual(invalid.timestamp, 0)
            XCTAssertEqual(invalid.audioResponse, off.audioResponse)
        }
    }

    func testPreviewAndExportReceiveIdenticalMaterialFrames() throws {
        let track = TrackInfo(track: Track(id: "12345678901", title: "Materials",
                                          thumbnailURL: nil, cleanArtist: "Test"),
                              fileName: nil, coverURL: nil)
        let beats = (0..<40).map { index in
            RhythmAnalysisResult.BeatEvent(time: Double(index) * 0.5,
                index: index, strength: 1, isDownbeat: index % 4 == 0)
        }
        let rhythm = RhythmAnalysisResult(onsetEvents: beats.map(\.time),
            bpmCandidates: [.init(bpm: 120, confidence: 0.9)], beatGrid: beats,
            confidence: 0.9, downbeatConfidence: 0.8)
        for id in ["original", "cyber-night", "liquid-dream", "neon-pulse"] {
            for speed: Float in [0.75, 1, 1.5] {
                let request = try StoryRequestBuilder.make(
                    mode: .player, track: track, theme: .acid, playerStyle: .turbulent,
                    karaokeBackground: .marble, marblePhase: 4, playbackTime: 2,
                    sourceDuration: 20, speed: speed, lines: [], lyricOffset: 0.4,
                    typography: .classic, includeAudio: false,
                    reactiveProgram: program(id), creativePresetID: id)
                let runtime = try XCTUnwrap(request.compositionRuntime)
                for profile in [StoryEncodingProfile.balanced, .economical] {
                    let grid = StoryRenderTimeline(request: request, profile: profile)
                    for index in [0, 11, 30] {
                        let frame = grid.frame(index: index)
                        let supplied = runtime.frame(at: frame.elapsed, audioTimeline: timeline(),
                                                     rhythmAnalysis: rhythm)
                        let preview = StorySceneView(request: request, artwork: nil, frame: frame,
                            visualTimeline: timeline(), visualRhythm: rhythm,
                            resolvedCompositionFrame: supplied)
                        let export = StorySceneView(request: request, artwork: nil, frame: frame,
                            visualTimeline: timeline(), visualRhythm: rhythm)
                        XCTAssertEqual(preview.materialFrame, export.materialFrame)
                        XCTAssertEqual(export.materialFrame, supplied?.materialFrame)
                        XCTAssertEqual(export.materialFrame.timestamp, frame.sourceTime)
                    }
                }
            }
        }
    }

    func testLegacyExperienceAndCodableCompatibility() throws {
        for id in CreativePresetCatalog.all.map(\.id) {
            let preset = try XCTUnwrap(CreativeExperiencePreset.fromLegacy(id))
            XCTAssertNil(preset.material)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(
                with: JSONEncoder().encode(preset)) as? [String: Any])
            object.removeValue(forKey: "material")
            let decoded = try JSONDecoder().decode(CreativeExperiencePreset.self,
                from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(decoded, preset)
            XCTAssertEqual(decoded.visualMaterial, .marble(for: preset.composition.program))
            let frame = try XCTUnwrap(CreativeExperienceResolver.resolve(
                decoded, elapsed: 2, features: features))
            XCTAssertEqual(frame.compositionFrame,
                CompositionRuntime(composition: preset.composition).frame(at: 2, features: features))
        }
        for material in VisualMaterialCatalog.all {
            XCTAssertEqual(try JSONDecoder().decode(VisualMaterial.self,
                from: JSONEncoder().encode(material)), material)
        }
        for preset in CreativePresetCatalog.selectableExperiences {
            XCTAssertEqual(try JSONDecoder().decode(CreativeExperiencePreset.self,
                from: JSONEncoder().encode(preset)), preset)
        }
        let old = Data(#"{"kind":"marble","beatPulse":0.6}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(VisualMaterial.self, from: old),
                       VisualMaterial(beatPulse: 0.6))
        let extreme = Data(#"{"distortion":99,"beatPulse":-1,"warpAmount":9}"#.utf8)
        let decoded = try JSONDecoder().decode(VisualParameterSet.self, from: extreme)
        XCTAssertEqual(decoded.distortion, 1)
        XCTAssertEqual(decoded.beatPulse, 0)
        XCTAssertEqual(decoded.warpAmount, 0.5)
    }

    func testOnlyMarbleIsSupportedAndCatalogContainsExactlyFourRecipes() {
        XCTAssertEqual(VisualMaterialCatalog.all.map(\.name),
                       ["Original Marble", "Cyber Chrome", "Liquid Dream", "Neon Pulse"])
        XCTAssertTrue(VisualMaterialCatalog.all.allSatisfy { $0.type == .marble })
        for type in VisualMaterialType.allCases where !type.isSupported {
            let reserved = VisualMaterial(id: "future", name: "Future", type: type)
            let frame = MaterialResolver.resolve(reserved, timestamp: 1)
            XCTAssertEqual(frame, MaterialResolver.resolve(.legacyMarble, timestamp: 1))
        }
    }

    @MainActor
    func testMarbleBeforeAfterPixelParity() throws {
        let material = VisualMaterial(beatPulse: 0.64)
        let old = CreativeParameterFrame(playerGlow: 0, marbleDistortion: 0.42,
                                         lyricKinetics: 0, particleEmission: 0)
        let pulse = legacyPulse(material, rhythm())
        let resolved = MaterialResolver.resolve(material, rhythm: rhythm(),
                                                 timestamp: 3, parameters: old)
        for theme in [MarbleTheme.acid, .cyber, .purewhite] {
            let before = TurbulentMarbleView(theme: theme, extendIntoSafeArea: false,
                frozenTime: 4.75, reactiveDistortion: old.marbleDistortion,
                beatPulse: pulse, material: material)
            let after = TurbulentMarbleView(theme: theme, extendIntoSafeArea: false,
                frozenTime: 4.75, materialFrame: resolved)
            func render(_ view: TurbulentMarbleView) throws -> UIImage {
                let renderer = ImageRenderer(content: view.frame(width: 128, height: 128))
                renderer.scale = 1
                return try XCTUnwrap(renderer.uiImage)
            }
            let first = try render(before)
            let second = try render(after)
            let image = try XCTUnwrap(first.cgImage)
            var pixels = [UInt32](repeating: 0, count: image.width * image.height)
            let context = try XCTUnwrap(CGContext(
                data: &pixels, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            XCTAssertGreaterThan(Set(pixels).count, 8, "Reject blank shader captures")
            XCTAssertEqual(first.pngData(), second.pngData(), "Marble pixel parity: \(theme)")
            for (label, image) in [("before", first), ("after", second)] {
                let attachment = XCTAttachment(image: image)
                attachment.name = "stage13-\(theme)-\(label)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testResolverCostAndMemoryFor10000Frames() {
        let material = VisualMaterialCatalog.neonPulse
        let rhythm = rhythm()
        var checksum = 0.0
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for index in 0..<10_000 {
                let frame = MaterialResolver.resolve(material, features: features,
                    rhythm: rhythm, timestamp: Double(index) / 60)
                checksum += frame.parameters.distortion + frame.parameters.beatPulse
            }
        }
        XCTAssertGreaterThan(checksum, 0)
        print("MATERIAL_LAYOUT frameBytes=\(MemoryLayout<MaterialFrame>.stride) parameterBytes=\(MemoryLayout<VisualParameterSet>.stride)")
    }
}
