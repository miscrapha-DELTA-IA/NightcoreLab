import AVFoundation
import Foundation
import XCTest
@testable import NightcoreLab

/// Stage 10C — Performance & Runtime Stabilization.
/// Every optimization here must be output-identical to the code it replaced.
final class RuntimeStabilizationTests: XCTestCase {

    @MainActor
    func testStage18C3VisibleMaterialBindingsAndCreatorNavigation() throws {
        let expected: [(String, [String])] = [
            ("neon-pulse", ["#040406", "#FF0088", "#00FF9D", "#00E5FF", "#F8FAFC"]),
            ("agate-zebra", ["#FFFFFF", "#050507", "#6C7A9C", "#F28C28", "#FFFFFF"]),
            ("void-gloss", ["#000000", "#00D2E6", "#00E5A3", "#F4DCE0", "#FF1A1A"]),
            ("terrazzo-magma", ["#0B0D11", "#E87A1E", "#D91414", "#D8DEC8", "#081E4A"]),
            ("airbrush-mirage", ["#121214", "#FF3B30", "#8E7CFF", "#FFB340", "#EBF2D5"]),
            ("groove-ebru", ["#008B94", "#F5A623", "#EE4035", "#F8B195", "#26292C"]),
            ("cymatic-rorschach", ["#050714", "#6699CC", "#F5F9FF", "#6699CC", "#050714"])
        ]
        let cyber = PlayerBackgroundView(style: .turbulent, imageURL: nil,
                                         theme: .cyber,
                                         material: CreativePresetCatalog.material(selection: "cyber-night"))
            .renderedSurface
        XCTAssertFalse(cyber.textured)
        for (id, hex) in expected {
            let card = PlayerBackgroundView(style: .blurred, imageURL: nil,
                                            theme: .cyber,
                                            material: CreativePresetCatalog.material(selection: id))
            let actual = card.renderedSurface
            XCTAssertEqual(actual.materialID, id)
            XCTAssertEqual(actual.paletteHex, hex)
            XCTAssertTrue(actual.textured)
            XCTAssertEqual(card.effectiveStyle, .turbulent)
            XCTAssertNotEqual(actual.parameters, cyber.parameters)
            XCTAssertNotEqual(actual.paletteHex, cyber.paletteHex)
            let shader = MarbleSurfaceBinding.resolve(material: card.resolvedMaterial)
            XCTAssertEqual(shader, actual) // identical data bound by TurbulentMarbleView
        }
        var route = CreatorStudioRoute()
        let selectedPreset = "void-gloss"
        let theme: AppTheme = .ultraviolet
        route.toggle()
        XCTAssertTrue(route.isPresented)
        XCTAssertEqual(selectedPreset, "void-gloss")
        XCTAssertEqual(theme, .ultraviolet)
        route.toggle()
        XCTAssertFalse(route.isPresented)
    }

    @MainActor
    func testStage18C3LivePCMMeterChangesOnScreenShaderWithModeGain() throws {
        let meter = AudioVisualLiveMeter()
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,
                                                    frameCapacity: 1024))
        buffer.frameLength = 1024
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<1024 {
            channel[i] = 0.45 * sin(Float(i) * 2 * .pi * 120 / 48_000)
        }
        meter.consume(buffer)
        let level = meter.snapshot()
        XCTAssertGreaterThan(level.rms, 0)
        XCTAssertGreaterThan(level.bass, 0)
        let base = MaterialResolver.resolve(VisualMaterialCatalog.neonPulse,
                                            timestamp: 2)
        let off = MarbleLiveResponse.apply(base, levels: level, mode: .off)
        let subtle = MarbleLiveResponse.apply(base, levels: level, mode: .subtle)
        let reactive = MarbleLiveResponse.apply(base, levels: level, mode: .responsive)
        XCTAssertEqual(off, base)
        XCTAssertGreaterThan(subtle.parameters.distortion, off.parameters.distortion)
        XCTAssertGreaterThan(reactive.parameters.distortion, subtle.parameters.distortion)
        XCTAssertGreaterThan(reactive.parameters.brightnessBoost,
                             subtle.parameters.brightnessBoost)
        XCTAssertEqual(reactive.parameters.stripingFrequency,
                       base.parameters.stripingFrequency)
        var controls = CreatorControls()
        controls.set(0.9, for: .brightness)
        let edited = MarbleCreatorResponse.apply(reactive, controls: controls)
        XCTAssertGreaterThan(edited.parameters.brightnessBoost,
                             reactive.parameters.brightnessBoost)
        XCTAssertEqual(edited.parameters.stripingMix, reactive.parameters.stripingMix)
        meter.reset()
        XCTAssertEqual(meter.snapshot(), .silence)
    }



    func testExp7CuratedMaterialsHaveUniquePalettesAndTextureTopology() throws {
        let ids = ["neon-pulse", "agate-zebra", "void-gloss", "terrazzo-magma",
                   "airbrush-mirage", "groove-ebru", "cymatic-rorschach"]
        let selected = ids.compactMap(CreativePresetCatalog.selectedExperience(id:))
        XCTAssertEqual(selected.count, ids.count)
        let materials = ids.map(CreativePresetCatalog.material(selection:))
        XCTAssertEqual(materials.map(\.id), ids)
        XCTAssertTrue(materials.allSatisfy { $0.parameters.usesProceduralTexture })
        XCTAssertEqual(VisualMaterialCatalog.curatedPalettes.count, 7)
        let palettes = ids.compactMap { VisualMaterialCatalog.curatedPalettes[$0]?.hex }
        XCTAssertEqual(palettes.count, ids.count)
        XCTAssertEqual(Set(palettes).count, ids.count)
        XCTAssertTrue(palettes.allSatisfy {
            $0.count == 5 && $0.allSatisfy {
                $0.count == 7 && $0.first == "#" &&
                $0.dropFirst().allSatisfy { $0.isHexDigit }
            }
        })
        XCTAssertEqual(VisualMaterialCatalog.curatedPalettes["neon-pulse"]?.hex,
                       ["#040406", "#FF0088", "#00FF9D", "#00E5FF", "#F8FAFC"])
        XCTAssertEqual(VisualMaterialCatalog.curatedPalettes["void-gloss"]?.hex,
                       ["#000000", "#00D2E6", "#00E5A3", "#F4DCE0", "#FF1A1A"])
        let fingerprints: [VisualParameterSet] = materials.map(\.parameters)
        XCTAssertEqual(Set(fingerprints.map {
            "\($0.stripingFrequency),\($0.stripingMix),\($0.speckleIntensity)," +
            "\($0.embossStrength),\($0.scanlineDensity),\($0.diffusionSoftness)," +
            "\($0.voidThreshold),\($0.combStretch),\($0.bilateralSymmetry)," +
            "\($0.halftoneGrating)"
        }).count, 7)
        XCTAssertGreaterThan(materials[0].parameters.stripingFrequency, 0)
        XCTAssertGreaterThan(materials[2].parameters.voidThreshold, 0.5)
        XCTAssertGreaterThan(materials[3].parameters.speckleIntensity, 0.5)
        XCTAssertGreaterThan(materials[4].parameters.scanlineDensity, 0)
        XCTAssertGreaterThan(materials[5].parameters.combStretch, 0)
        XCTAssertEqual(materials[6].parameters.bilateralSymmetry, 1)

        let cyber = CreativePresetCatalog.material(selection: "cyber-night")
        XCTAssertFalse(cyber.parameters.usesProceduralTexture)
        XCTAssertNotEqual(materials[0].parameters, cyber.parameters)
        XCTAssertNil(VisualMaterialCatalog.curatedPalettes[cyber.id])
        for material in materials {
            XCTAssertEqual(try JSONDecoder().decode(
                VisualMaterial.self, from: JSONEncoder().encode(material)), material)
            let frame = MaterialResolver.resolve(material, timestamp: 12,
                                                 reactionGain: 0)
            XCTAssertEqual(frame.parameters.stripingMix, material.parameters.stripingMix)
            XCTAssertEqual(frame.parameters.voidThreshold, material.parameters.voidThreshold)
            XCTAssertEqual(frame.parameters.scanlineDensity, material.parameters.scanlineDensity)
            XCTAssertEqual(frame.parameters.halftoneGrating, material.parameters.halftoneGrating)
            XCTAssertEqual(frame.parameters.beatPulse, 0)
        }
    }

    func testExp7VisualParameterSetCodableLegacyAndClamping() throws {
        let wild = VisualParameterSet(
            stripingFrequency: 999, stripingMix: 7,
            speckleIntensity: .nan, embossStrength: .infinity,
            scanlineDensity: 999, diffusionSoftness: -1,
            voidThreshold: 4, combStretch: 40,
            bilateralSymmetry: 9, halftoneGrating: 300)
        XCTAssertEqual(wild.stripingFrequency, 80)
        XCTAssertEqual(wild.stripingMix, 1)
        XCTAssertEqual(wild.speckleIntensity, 0)
        XCTAssertEqual(wild.embossStrength, 0)
        XCTAssertEqual(wild.scanlineDensity, 160)
        XCTAssertEqual(wild.diffusionSoftness, 0)
        XCTAssertEqual(wild.voidThreshold, 1)
        XCTAssertEqual(wild.combStretch, 8)
        XCTAssertEqual(wild.bilateralSymmetry, 1)
        XCTAssertEqual(wild.halftoneGrating, 120)
        XCTAssertEqual(try JSONDecoder().decode(
            VisualParameterSet.self, from: JSONEncoder().encode(wild)), wild)
        let legacy = Data(#"{"distortion":0.2,"beatPulse":0.6,"pulseDecay":6,"offbeatScale":0.7,"warpAmount":0.18,"brightnessBoost":0.1}"#.utf8)
        let restored = try JSONDecoder().decode(VisualParameterSet.self, from: legacy)
        XCTAssertEqual(restored, VisualParameterSet(distortion: 0.2, beatPulse: 0.6))
        XCTAssertFalse(restored.usesProceduralTexture)
        XCTAssertFalse(VisualParameterSet.neutral.usesProceduralTexture)
    }



    @MainActor
    func testExp5MusicalGridAndOptionalQuantizeAreDeterministic() throws {
        let beats = (0..<12).map {
            RhythmAnalysisResult.BeatEvent(time: Double($0) * 0.5,
                index: $0, strength: 0.9, isDownbeat: $0.isMultiple(of: 4))
        }
        let rhythm = RhythmAnalysisResult(
            onsetEvents: [], bpmCandidates: [.init(bpm: 120, confidence: 0.95)],
            beatGrid: beats, confidence: 0.95, downbeatConfidence: 0.95)
        let position = try XCTUnwrap(PadMusicalGrid.at(1.06, rhythm: rhythm))
        XCTAssertEqual(position.beat, 2.12, accuracy: 0.000001)
        XCTAssertEqual(position.bar, 1)
        XCTAssertEqual(position.bpm, 120, accuracy: 0.000001)
        XCTAssertEqual(position.nearestGridSourceTime ?? -1, 1, accuracy: 0.000001)
        XCTAssertEqual(PadMusicalGrid.time(forBeat: 2.12, rhythm: rhythm) ?? -1,
                       1.06, accuracy: 0.000001)
        XCTAssertEqual(PadMusicalGrid.at(2.25, rhythm: rhythm)?.bar, 2)

        let sample = try XCTUnwrap(PadKit.starter.samples.first)
        let recorder = PerformanceRecorder()
        recorder.start(at: 10)
        recorder.append(sample, velocity: 0.8, sourceTime: 1.06,
                        at: 10.2, rhythm: rhythm)
        recorder.stop()
        let event = try XCTUnwrap(recorder.events.first)
        XCTAssertEqual(event.timestamp, 0.2, accuracy: 0.000001)
        XCTAssertEqual(event.musicalBeat ?? -1, 2.12, accuracy: 0.000001)
        XCTAssertEqual(event.musicalBar, 1)
        XCTAssertEqual(event.bpmAtTrigger ?? -1, 120, accuracy: 0.000001)
        XCTAssertEqual(CompositionRuntime.padEventSourceTime(event,
            quantizeStrength: 0) ?? -1, 1.06, accuracy: 0.000001)
        XCTAssertEqual(CompositionRuntime.padEventSourceTime(event,
            quantizeStrength: 0.5) ?? -1, 1.03, accuracy: 0.000001)
        XCTAssertEqual(CompositionRuntime.padEventSourceTime(event,
            quantizeStrength: 1) ?? -1, 1, accuracy: 0.000001)
        for (strength, expected) in [(Float(0), Int64(50_880)),
                                     (0.5, 49_440), (1, 48_000)] {
            let timeline = recorder.timeline(quantizeStrength: strength)
            let schedule = try PerformancePadMixdown.schedule(
                timeline, kit: .starter, startTime: 0,
                speed: 1, sampleRate: 48_000)
            XCTAssertEqual(schedule.first?.startFrame, expected)
            XCTAssertEqual(try JSONDecoder().decode(
                PerformanceTimeline.self,
                from: JSONEncoder().encode(timeline)), timeline)
        }
        // Missing legacy v1 musical keys and strength must keep raw timing.
        let legacy = PadEvent(id: UUID(), padId: sample.id, timestamp: 0.2,
                              velocity: 0.8, duration: sample.duration,
                              sourceTime: 1.06)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:
            JSONEncoder().encode(PerformanceTimeline(
                kitID: PadKit.starter.id, events: [legacy]))) as? [String: Any])
        json.removeValue(forKey: "quantizeStrength")
        let restored = try JSONDecoder().decode(PerformanceTimeline.self,
                         from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(restored.isValid)
        XCTAssertEqual(restored.quantizeStrength, 0)
        XCTAssertNil(restored.events.first?.musicalBeat)
        XCTAssertEqual(restored.events.first?.timestamp ?? -1, 0.2, accuracy: 0.000001)
    }



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
