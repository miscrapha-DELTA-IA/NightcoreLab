import AVFoundation
import Foundation
import XCTest
@testable import NightcoreLab

/// Stage 10C — Performance & Runtime Stabilization.
/// Every optimization here must be output-identical to the code it replaced.
final class RuntimeStabilizationTests: XCTestCase {

    func testExp4SongDNAMappingAndSectionBoundariesAreDeterministic() throws {
        let sections = [
            MusicSection(startTime: 0, endTime: 8, label: .intro, confidence: 0.9),
            MusicSection(startTime: 8, endTime: 24, label: .verse, confidence: 0.9),
            MusicSection(startTime: 24, endTime: 40, label: .chorus, confidence: 0.95),
            MusicSection(startTime: 40, endTime: 50, label: .buildup, confidence: 0.8)
        ]
        let dna = SongDNA(assetID: "fixture-song", sourceRevision: "revision-1",
                          sourceDuration: 60, bpm: 152,
                          beatTimestamps: [0, 0.395, 0.790], energy: 0.8,
                          sections: sections)
        XCTAssertTrue(dna.isValid)
        let decoded = try JSONDecoder().decode(SongDNA.self,
                                               from: JSONEncoder().encode(dna))
        XCTAssertEqual(decoded, dna)
        XCTAssertEqual(SongCreativeProfileResolver.suggest(dna: dna),
                       SongCreativeProfileResolver.suggest(dna: decoded))
        let profile = SongCreativeProfileResolver.suggest(dna: dna)
        XCTAssertEqual(profile.visualPresetID, "neon-pulse")
        XCTAssertEqual(profile.padKitID, PadKit.starter.id)
        XCTAssertEqual(profile.padMapping.bpm, 152)
        XCTAssertFalse(profile.padMapping.melodicPadTuningActive)

        XCTAssertEqual(dna.section(at: 7.999)?.label, .intro)
        XCTAssertEqual(dna.section(at: 8)?.label, .verse)
        XCTAssertEqual(dna.section(at: 24)?.label, .chorus)
        XCTAssertEqual(dna.section(at: 40)?.label, .buildup)
        XCTAssertNil(dna.section(at: 55))
        XCTAssertLessThan(SongSectionCadence.at(sourceTime: 1, dna: dna).visual,
                          SongSectionCadence.at(sourceTime: 25, dna: dna).visual)

        let parameters = CreativeParameterFrame(
            playerGlow: 0.8, marbleDistortion: 0.6,
            lyricKinetics: 0.5, particleEmission: 0.4)
        XCTAssertEqual(SongSectionCadence.apply(parameters, cadence:
            .at(sourceTime: 25, dna: dna)), parameters)
        XCTAssertEqual(SongSectionCadence.apply(parameters, cadence:
            .at(sourceTime: 1, dna: dna)).playerGlow, 0.52, accuracy: 0.0001)

        let fallback = SongDNA(assetID: "fixture-song", sourceRevision: "revision-1",
                               sourceDuration: 60)
        XCTAssertTrue(fallback.isValid)
        XCTAssertEqual(SongCreativeProfileResolver.suggest(dna: fallback).visualPresetID,
                       CreativePresetCatalog.defaultID)
        XCTAssertEqual(SongSectionCadence.at(sourceTime: 24, dna: fallback), .neutral)
    }


    // MARK: Deterministic fixtures

    /// Small LCG so fixtures are identical on every run and device.
    private struct Generator {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func value(in range: ClosedRange<Double>) -> Double {
            range.lowerBound + (range.upperBound - range.lowerBound) * next()
        }
    }

    private func composition(seed: UInt64) throws -> VisualComposition {
        var random = Generator(state: seed)
        let duration = 12.0
        let easings: [CompositionEasing] = [.hold, .linear, .easeInOut]
        let kinds: [PresetLayerKind] = [.background, .artwork, .typography, .overlay]
        var layers: [PresetLayer] = []
        for (index, kind) in kinds.enumerated() {
            var keyframes: [CompositionKeyframe] = []
            for property in LayerProperty.allCases {
                // Authored out of order on purpose: the runtime must sort.
                let times = (0..<4).map { _ in (random.value(in: 0...duration) * 100).rounded() / 100 }
                for (offset, time) in Set(times).sorted(by: >).enumerated() {
                    keyframes.append(CompositionKeyframe(
                        timestamp: time, property: property,
                        value: random.value(in: property.bounds),
                        easing: easings[offset % easings.count]))
                }
            }
            let bindings: [LayerAudioBinding] = index.isMultiple(of: 2) ? [
                LayerAudioBinding(property: .opacity,
                                  equation: CreativeEquation(signal: .bass, operation: .multiply,
                                                             gain: 0.8, bias: 0.2)),
                LayerAudioBinding(property: .scale,
                                  equation: CreativeEquation(signal: .timeSine, operation: .add,
                                                             gain: 0.3, frequency: 0.5))
            ] : []
            layers.append(PresetLayer(
                id: "layer-\(index)", kind: kind,
                // Equal zIndex for two layers exercises the id tie-break.
                zIndex: index == 3 ? 10 : index * 10,
                activeRange: index == 1 ? CompositionClip(start: 2, end: 9) : nil,
                properties: [.intensity: random.value(in: 0...1)],
                bindings: bindings, keyframes: keyframes))
        }
        let timeline = try CompositionTimeline(sourceStart: 4, playbackSpeed: 1.25,
                                               duration: duration)
        return try VisualComposition(
            id: "stage-10c", name: "Stage 10C",
            program: CreativePresetCatalog.program(for: "bass-pulse"),
            layers: layers.reversed(), timeline: timeline, deterministicSeed: seed)
    }

    private func features(_ index: Int) -> AudioFeatures? {
        switch index % 4 {
        case 0: return nil
        case 1: return .silent
        default:
            let x = Double(index % 37) / 37
            return AudioFeatures(bass: x, mid: 1 - x, treble: x * 0.5,
                                 energy: 0.3 + x * 0.6, beatDetected: index % 3 == 0)
        }
    }

    // MARK: Equivalence

    func testCompiledRuntimeMatchesLegacyResolverExactly() throws {
        for seed: UInt64 in [1, 42, 0xC0FFEE] {
            let comp = try composition(seed: seed)
            let runtime = CompositionRuntime(composition: comp)
            for index in 0...600 {
                // Includes exact keyframe hits (2-decimal grid) and the end.
                let elapsed = Double(index) * 0.02
                let input = features(index)
                // Stage 13 adds material output; compare every pre-existing
                // field against the untouched reference, then test material separately.
                var current = runtime.frame(at: elapsed, features: input)
                XCTAssertNotNil(current?.materialFrame)
                current?.materialFrame = nil
                XCTAssertEqual(
                    current,
                    LegacyCompositionResolver.resolve(comp, elapsed: elapsed, features: input),
                    "seed \(seed) elapsed \(elapsed)")
            }
            XCTAssertNil(runtime.frame(at: -0.01, features: nil))
            XCTAssertNil(runtime.frame(at: .nan, features: nil))
            XCTAssertNil(runtime.frame(at: 12.01, features: nil))
        }
    }

    func testStaticResolverAndRuntimeAgree() throws {
        let comp = try composition(seed: 7)
        let runtime = CompositionRuntime(composition: comp)
        for index in 0...100 {
            let elapsed = Double(index) * 0.11
            XCTAssertEqual(CompositionFrameResolver.resolve(comp, elapsed: elapsed,
                                                            features: features(index)),
                           runtime.frame(at: elapsed, features: features(index)))
        }
    }

    // MARK: Frozen Story runtime

    private func storyRequest() throws -> StoryVideoRequest {
        let line = TimedLyricLine(id: 0, start: 1, end: 8, words: [
            WordSync(id: 0, text: "STABLE", start: 1, end: 4, spaceAfter: true),
            WordSync(id: 1, text: "RUNTIME", start: 4, end: 8, spaceAfter: false)
        ], precision: .word)
        let track = TrackInfo(track: Track(id: "12345678901", title: "Runtime",
                                           thumbnailURL: nil, cleanArtist: "Nightcore"),
                              fileName: nil, coverURL: nil)
        return try StoryRequestBuilder.make(
            mode: .lyrics, track: track, theme: .acid,
            playerStyle: .turbulent, karaokeBackground: .marble,
            marblePhase: 1, playbackTime: 0.5, sourceDuration: 20,
            speed: 1.25, lines: [line], lyricOffset: 0.1,
            typography: .classic, typographyStyle: .magazineCutout,
            includeAudio: false,
            reactiveProgram: CreativePresetCatalog.effectiveProgram(
                id: "bass-pulse", theme: .acid, typography: .magazineCutout,
                background: .turbulent, reaction: .responsive),
            reactiveSourceURL: nil)
    }

    func testStoryFreezesOneRuntimeAndPreparedLyrics() throws {
        let request = try storyRequest()
        let runtime = try XCTUnwrap(request.compositionRuntime)
        XCTAssertEqual(request.visualComposition, runtime.composition)
        XCTAssertEqual(Set(request.preparedLyrics.keys), [0])

        let grid = StoryRenderTimeline(request: request, profile: .balanced)
        for index in [0, 10, 40, 90, grid.lastFrameIndex] {
            let renderFrame = grid.frame(index: index)
            let scene = StorySceneView(request: request, artwork: nil, frame: renderFrame)
            // Same output as resolving from scratch without any cache.
            let layer = TypographyLayer.forStory(
                lines: request.lines, lyricTime: renderFrame.lyricTime,
                lyricOffset: request.lyricOffset, preset: request.typographyPreset)
            let uncached = CompositionRuntime(composition: runtime.composition).frame(
                at: renderFrame.elapsed, audioTimeline: nil, typography: layer)
            XCTAssertEqual(scene.resolvedCompositionFrame, uncached)
            XCTAssertEqual(scene.typographyFrame, uncached?.typographyFrame)
        }
    }

    func testPreparedLineIsOnlyAnOptimization() throws {
        let request = try storyRequest()
        let line = request.lines[0]
        for time in stride(from: 1.0, to: 8.0, by: 0.37) {
            let state = LyricsState(line: line, status: .active)
            XCTAssertEqual(
                TypographyResolver.resolve(state, at: time, features: nil,
                                           preset: request.typographyPreset,
                                           prepared: request.preparedLyrics[line.id]),
                TypographyResolver.resolve(state, at: time, features: nil,
                                           preset: request.typographyPreset))
        }
    }

    func testAssigningVisualCompositionRebuildsTheRuntime() throws {
        var request = try storyRequest()
        let replacement = try composition(seed: 9)
        request.visualComposition = replacement
        XCTAssertEqual(request.compositionRuntime?.composition, replacement)
        request.visualComposition = nil
        XCTAssertNil(request.compositionRuntime)
    }

    // MARK: Live uniforms

    @MainActor
    func testLiveUniformsFreezeAndUpdateOnlyOnChange() {
        let uniforms = CreativeLiveUniforms()
        XCTAssertEqual(uniforms.marbleDistortion, 0)
        let a = CreativeParameterFrame(playerGlow: 0.2, marbleDistortion: 0.4,
                                       lyricKinetics: 0, particleEmission: 0)
        uniforms.update(a)
        XCTAssertEqual(uniforms.marbleDistortion, 0.4)
        uniforms.freeze()
        uniforms.update(CreativeParameterFrame(playerGlow: 1, marbleDistortion: 0.9,
                                               lyricKinetics: 0, particleEmission: 0))
        XCTAssertEqual(uniforms.marbleDistortion, 0.4, "Sharing freezes the visible Marble")
        uniforms.unfreeze()
        XCTAssertEqual(uniforms.marbleDistortion, 0.9)
    }

    // MARK: Identity cache

    private func audio(_ directory: URL, amplitude: Float = 0.3) throws -> URL {
        let url = directory.appendingPathComponent("identity").appendingPathExtension("caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_000))
        buffer.frameLength = 4_000
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<4_000 {
            samples[index] = amplitude * Float(sin(2 * .pi * 110 * Double(index) / 16_000))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    func testIdentityCacheMatchesFullReadAndDetectsChanges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try audio(directory)
        let cache = AssetIdentityCache()

        let first = try await cache.descriptor(for: url)
        XCTAssertEqual(first, try AudioAssetDescriptor.read(at: url))
        let again = try await cache.descriptor(for: url)
        XCTAssertEqual(again, first)
        try await cache.validate(first)

        // Rewrite the same file with different content (new stamp, new hash).
        try FileManager.default.removeItem(at: url)
        _ = try audio(directory, amplitude: 0.7)

        do {
            try await cache.validate(first)
            XCTFail("Changed content must invalidate the cached identity")
        } catch AudioAssetDescriptor.IdentityError.sourceChanged {}
        let changed = try await cache.descriptor(for: url)
        XCTAssertNotEqual(changed.sourceRevision, first.sourceRevision)
        XCTAssertEqual(changed, try AudioAssetDescriptor.read(at: url))
    }

    // MARK: Cost (reported by XCTest; compare on device, not in CI)

    func testPerformanceCompiledRuntime1000Frames() throws {
        let runtime = CompositionRuntime(composition: try composition(seed: 3))
        measure {
            for index in 0..<1_000 {
                _ = runtime.frame(at: Double(index) * 0.012, features: features(index))
            }
        }
    }

    func testPerformanceLegacyResolver1000Frames() throws {
        let comp = try composition(seed: 3)
        measure {
            for index in 0..<1_000 {
                _ = LegacyCompositionResolver.resolve(
                    comp, elapsed: Double(index) * 0.012, features: features(index))
            }
        }
    }

    func testPerformanceStorySceneResolution300Frames() throws {
        let request = try storyRequest()
        let grid = StoryRenderTimeline(request: request, profile: .balanced)
        measure {
            for index in 0..<min(300, grid.frameCount) {
                _ = StorySceneView(request: request, artwork: nil,
                                   frame: grid.frame(index: index)).typographyFrame
            }
        }
    }
}

/// Verbatim copy of the pre-10C CompositionFrameResolver (commit d4b05d6),
/// kept as the reference implementation for equivalence and cost baselines.
private enum LegacyCompositionResolver {
    static func resolve(_ composition: VisualComposition,
                        elapsed: TimeInterval,
                        features: AudioFeatures? = nil) -> ResolvedCompositionFrame? {
        guard composition.isValid,
              let timestamp = composition.timeline.timestamp(at: elapsed) else {
            return nil
        }

        let source = features ?? .silent
        let response = AudioVisualMapper.map(source, preset: composition.program.preset)
        let programFrame = CreativeParameterResolver.resolve(
            program: composition.program,
            response: response, features: source,
            sourceTime: timestamp.sourceTime)

        let resolvedLayers: [ResolvedLayerFrame] = composition.orderedLayers
            .filter { $0.isActive(at: timestamp.elapsed) }
            .map { layer in
                var values: [LayerProperty: Double] = [:]
                for property in LayerProperty.allCases {
                    let authored = layer.properties[property] ?? property.defaultValue
                    let animated = keyframed(property, layer: layer,
                                            elapsed: timestamp.elapsed) ?? authored
                    if let binding = layer.bindings.first(where: { $0.property == property }),
                       features != nil {
                        values[property] = binding.apply(
                            to: animated, features: source,
                            sourceTime: timestamp.sourceTime,
                            reaction: composition.program.preset.audioReaction)
                    } else {
                        values[property] = property.clamped(animated)
                    }
                }
                return ResolvedLayerFrame(id: layer.id, kind: layer.kind,
                                          zIndex: layer.zIndex, values: values)
            }

        return ResolvedCompositionFrame(
            compositionID: composition.id,
            timestamp: timestamp,
            deterministicSeed: composition.deterministicSeed,
            programParameters: programFrame,
            layers: resolvedLayers,
            typographyFrame: nil)
    }

    private static func keyframed(_ property: LayerProperty,
                                  layer: PresetLayer,
                                  elapsed: TimeInterval) -> Double? {
        let points = layer.keyframes.filter { $0.property == property }
            .sorted { $0.timestamp < $1.timestamp }
        guard let first = points.first else { return nil }
        guard elapsed > first.timestamp else { return first.value }
        guard let last = points.last, elapsed < last.timestamp else {
            return points.last?.value
        }

        for index in 1..<points.count {
            let upper = points[index]
            guard elapsed <= upper.timestamp else { continue }
            if elapsed == upper.timestamp { return upper.value }
            let lower = points[index - 1]
            let duration = upper.timestamp - lower.timestamp
            guard duration > 0 else { return upper.value }
            let ratio = upper.easing.progress((elapsed - lower.timestamp) / duration)
            return lower.value + (upper.value - lower.value) * ratio
        }
        return last.value
    }
}
