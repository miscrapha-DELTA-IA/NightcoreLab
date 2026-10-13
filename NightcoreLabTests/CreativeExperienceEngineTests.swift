import Foundation
import XCTest
@testable import NightcoreLab

final class CreativeExperienceEngineTests: XCTestCase {
    private func audio(bass: Double = 0.6, energy: Double = 0.45,
                       treble: Double = 0.35, beat: Bool = false) -> AudioFeatures {
        AudioFeatures(bass: bass, mid: 0.25, treble: treble,
                      energy: energy, beatDetected: beat)
    }

    private func lyricLayer() -> TypographyLayer {
        let line = TimedLyricLine(id: 11, start: 1, end: 4, words: [
            WordSync(id: 0, text: "CYBER", start: 1, end: 2.5,
                     spaceAfter: true),
            WordSync(id: 1, text: "NIGHT", start: 2.5, end: 4,
                     spaceAfter: false)
        ], precision: .word)
        return TypographyLayer(
            state: LyricsState(line: line, status: .active),
            preset: TypographyPreset(style: .neon), lyricOffset: 0.25)
    }

    private func selected(_ id: String = "cyber-night") throws -> CreativeExperiencePreset {
        try XCTUnwrap(CreativePresetCatalog.experience(for: id))
    }

    func testSamePresetTimestampAndAudioGiveSameExperienceAfterOutOfOrderSeeks() throws {
        let preset = try selected()
        let features = audio(beat: true)
        let a = try XCTUnwrap(CreativeExperienceResolver.resolve(
            preset, elapsed: 1.9, features: features, typography: lyricLayer()))
        _ = CreativeExperienceResolver.resolve(
            preset, elapsed: 7, features: audio(), typography: lyricLayer())
        let b = try XCTUnwrap(CreativeExperienceResolver.resolve(
            preset, elapsed: 1.9, features: features, typography: lyricLayer()))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.experienceID, "cyber-night")
        XCTAssertEqual(a.timestamp.sourceTime, 1.9, accuracy: 1e-12)
        XCTAssertEqual(a.timestamp.elapsed, 1.9, accuracy: 1e-12)
        XCTAssertEqual(a.typographyFrame,
                       a.compositionFrame.typographyFrame)
        XCTAssertNotNil(a.typographyFrame?.animations[0])
    }

    func testTypedFrequencyIsTrebleBandAndAudioMappingIsBounded() throws {
        let map = CreativeAudioMapping(enabled: true, bindings: [
            .init(signal: .bass, target: .visualIntensity, gain: 0.5),
            .init(signal: .energy, target: .visualIntensity, gain: 0.5),
            .init(signal: .frequency, target: .movement, gain: 0.25),
            .init(signal: .beat, target: .typographyIntensity, gain: 0.4)
        ])
        let base = map.resolve(features: audio(
            bass: 0.8, energy: 0.4, treble: 0.6, beat: true))
        XCTAssertEqual(base.visualIntensity, 0.6, accuracy: 1e-12)
        XCTAssertEqual(base.typographyIntensity, 0.4, accuracy: 1e-12)
        XCTAssertEqual(base.movement, 0.15, accuracy: 1e-12)
        XCTAssertEqual(map.resolve(features: nil), .neutral)
        XCTAssertEqual(CreativeAudioMapping.disabled.resolve(
            features: audio(beat: true)), .neutral)
        let extreme = map.resolve(features: audio(
            bass: 10, energy: 10, treble: 10, beat: true))
        XCTAssertEqual(extreme.visualIntensity, 1)
        XCTAssertTrue(map.isValid)
    }

    func testFeatureChangesAffectOnlyMappedExperienceOutputs() throws {
        let base = try selected("cyber-night")
        let without = try XCTUnwrap(CreativeExperienceResolver.resolve(
            base, elapsed: 1.7, features: audio(bass: 0, energy: 0,
                                               treble: 0, beat: false),
            typography: lyricLayer()))
        let with = try XCTUnwrap(CreativeExperienceResolver.resolve(
            base, elapsed: 1.7, features: audio(bass: 0, energy: 0,
                                               treble: 0, beat: true),
            typography: lyricLayer()))
        XCTAssertEqual(without.audioState.visualIntensity,
                       with.audioState.visualIntensity)
        XCTAssertEqual(without.audioState.movement, with.audioState.movement)
        XCTAssertLessThan(without.audioState.typographyIntensity,
                          with.audioState.typographyIntensity)
        XCTAssertEqual(without.visualFrame.intensity,
                       with.visualFrame.intensity)
        XCTAssertEqual(without.visualFrame.movement,
                       with.visualFrame.movement)
        // Legacy CreativeVisualProgram can also react to beat/mid; each
        // result must match that existing runtime, never override it.
        XCTAssertEqual(without.compositionFrame.programParameters,
            CompositionRuntime(composition: base.composition).frame(
                at: 1.7,
                features: audio(bass: 0, energy: 0,
                                treble: 0, beat: false))?.programParameters)
        XCTAssertEqual(with.compositionFrame.programParameters,
            CompositionRuntime(composition: base.composition).frame(
                at: 1.7,
                features: audio(bass: 0, energy: 0,
                                treble: 0, beat: true))?.programParameters)
        XCTAssertEqual(without.compositionFrame.layers,
                       with.compositionFrame.layers)
        XCTAssertEqual(without.typographyFrame?.words.map(\.progress),
                       with.typographyFrame?.words.map(\.progress))
        XCTAssertNotEqual(without.typographyFrame?.animations,
                          with.typographyFrame?.animations)
    }

    func testLegacyPresetsProduceExactlyExistingRuntimeParametersAndLayers() throws {
        for id in ["original", "bass-pulse", "night-drive", "soft-flow"] {
            let experience = try selected(id)
            XCTAssertEqual(experience.composition.program,
                           CreativePresetCatalog.program(for: id))
            XCTAssertEqual(experience.audioMapping, .disabled)
            XCTAssertEqual(experience.visualPreset,
                           experience.composition.program.preset.visualStyle)
            for elapsed in [0.0, 1.2, 3.4, 6.75, 14.0] {
                for sample in [Optional<AudioFeatures>.none, audio(beat: true)] {
                    let runtime = try XCTUnwrap(
                        CompositionRuntime(composition: experience.composition)
                            .frame(at: elapsed, features: sample))
                    let frame = try XCTUnwrap(CreativeExperienceResolver.resolve(
                        experience, elapsed: elapsed, features: sample))
                    XCTAssertEqual(frame.compositionFrame, runtime)
                    XCTAssertEqual(frame.visualFrame.parameters,
                                   runtime.programParameters)
                    XCTAssertEqual(frame.audioState, .neutral)
                    XCTAssertEqual(frame.visualFrame.intensity,
                                   experience.visualPreset.intensity)
                    XCTAssertEqual(frame.visualFrame.movement,
                                   experience.visualPreset.motion)
                }
            }
        }
    }

    func testSameSourceTimeOnDifferentPlaybackSpeedsAndLyricOffset() throws {
        let demo = try selected("neon-pulse")
        let original = demo.composition
        let timeline = try CompositionTimeline(
            sourceStart: 10, playbackSpeed: 1.5, duration: 8)
        let rebased = try VisualComposition(
            id: original.id, name: original.name, program: original.program,
            layers: original.layers, timeline: timeline,
            deterministicSeed: original.deterministicSeed)
        let package = try CreativePresetPackage(
            id: rebased.id, name: rebased.name, author: demo.author,
            composition: rebased, typographyPreset: demo.typographyPreset)
        let changed = try CreativeExperiencePreset(
            package: package, description: demo.description,
            audioMapping: demo.audioMapping, exportStyle: demo.exportStyle)
        let result = try XCTUnwrap(CreativeExperienceResolver.resolve(
            changed, elapsed: 2, features: audio(beat: true)))
        XCTAssertEqual(result.timestamp.elapsed, 2)
        XCTAssertEqual(result.timestamp.sourceTime, 13)
        XCTAssertNil(CreativeExperienceResolver.resolve(
            changed, elapsed: 8.1, features: audio()))
        XCTAssertNil(CreativeExperienceResolver.resolve(
            changed, elapsed: .infinity, features: audio()))
    }

    func testPreviewAndExportAdaptersSeeTheSameFrozenCompositionFrame() throws {
        let experience = try selected("neon-pulse")
        let frozen = CompositionRuntime(composition: experience.composition)
        let lyric = lyricLayer()
        for elapsed in [0.0, 1.0, 1.25, 2.5, 3.0] {
            let sample = audio(bass: 0.82, beat: true)
            let preview = try XCTUnwrap(CreativeExperienceResolver.resolve(
                experience, elapsed: elapsed,
                features: sample, typography: lyric))
            let exported = try XCTUnwrap(frozen.experienceFrame(
                at: elapsed, preset: experience,
                features: sample, typography: lyric))
            XCTAssertEqual(preview, exported)
            XCTAssertEqual(preview.compositionFrame,
                           exported.compositionFrame)
            XCTAssertEqual(preview.compositionFrame.timestamp,
                           exported.compositionFrame.timestamp)
            XCTAssertEqual(preview.typographyFrame,
                           exported.typographyFrame)
        }
    }

    func testInvalidOrMismatchedRuntimeCompositionIsRejected() throws {
        let chosen = try selected()
        let other = try selected("liquid-dream")
        let runtime = CompositionRuntime(composition: chosen.composition)
        XCTAssertNil(runtime.experienceFrame(
            at: 1.0, preset: other, features: audio()))
        XCTAssertNotNil(runtime.experienceFrame(
            at: 1.0, preset: chosen, features: audio()))
    }

    func testAllThreeCuratedPresetsUseExistingProgramsAndTypedStyles() throws {
        let ids = ["cyber-night", "liquid-dream", "neon-pulse"]
        XCTAssertEqual(Array(CreativePresetCatalog.experiencePresets.prefix(3).map(\.id)), ids)
        XCTAssertGreaterThanOrEqual(CreativePresetCatalog.experiencePresets.count, ids.count)
        for id in ids {
            let experience = try selected(id)
            XCTAssertTrue(experience.isValid)
            XCTAssertEqual(experience.visualPreset.background, .marble)
            XCTAssertEqual(experience.package.composition.id, experience.id)
            XCTAssertEqual(experience.audioMapping.enabled, true)
            XCTAssertEqual(experience.exportStyle, .portrait)
            let frame = try XCTUnwrap(CreativeExperienceResolver.resolve(
                experience, elapsed: 1.5,
                features: audio(beat: true), typography: lyricLayer()))
            XCTAssertEqual(frame.experienceID, id)
            XCTAssertNotNil(frame.compositionFrame.typographyFrame)
        }
        XCTAssertEqual(try selected("cyber-night").typographyPreset.style, .glitch)
        XCTAssertEqual(try selected("liquid-dream").typographyPreset.style,
                       .magazineCutout)
        XCTAssertEqual(try selected("neon-pulse").typographyPreset.style, .kinetic)
        XCTAssertNil(CreativePresetCatalog.experience(for: "invalid-id"))
    }

    func testCodableRoundTripRetainsCompleteAuthoringData() throws {
        for id in ["original", "bass-pulse", "night-drive", "soft-flow",
                   "cyber-night", "liquid-dream", "neon-pulse"] {
            let value = try selected(id)
            let serialized = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(
                CreativeExperiencePreset.self, from: serialized)
            XCTAssertEqual(value, decoded)
            XCTAssertEqual(value.composition, decoded.composition)
            XCTAssertEqual(value.typographyPreset, decoded.typographyPreset)
            XCTAssertEqual(value.package.audioMapping,
                           decoded.package.audioMapping)
            XCTAssertEqual(value.schemaVersion, 1)
        }
    }

    func testUnknownSchemasAndCorruptMappingsFailSafely() throws {
        let preset = try selected()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(preset)) as? [String: Any])
        json["schemaVersion"] = 2
        XCTAssertThrowsError(try JSONDecoder().decode(
            CreativeExperiencePreset.self,
            from: JSONSerialization.data(withJSONObject: json)))
        json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(preset)) as? [String: Any])
        json["audioMapping"] = [
            "enabled": true,
            "bindings": [
                ["signal": "beat", "target": "movement", "gain": 0.4],
                ["signal": "beat", "target": "movement", "gain": 0.9]
            ]
        ]
        XCTAssertThrowsError(try JSONDecoder().decode(
            CreativeExperiencePreset.self,
            from: JSONSerialization.data(withJSONObject: json)))
        json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(preset)) as? [String: Any])
        json.removeValue(forKey: "package")
        XCTAssertThrowsError(try JSONDecoder().decode(
            CreativeExperiencePreset.self,
            from: JSONSerialization.data(withJSONObject: json)))
    }

    func testStoreAndExperienceCatalogReuseExistingLocalPackages() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("experience-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CreativePresetPackageStore(directory: directory)
        let existing = try XCTUnwrap(
            CreativePresetCatalog.builtInPackage(for: "original"))
        let source = existing.composition.program
        let custom = CreativePreset(
            id: "local-experience", name: "Local Experience",
            theme: source.preset.theme,
            typographyStyle: source.preset.typographyStyle,
            visualStyle: source.preset.visualStyle,
            audioReaction: source.preset.audioReaction)
        let program = CreativeVisualProgram(preset: custom, rules: source.rules)
        let composition = try VisualComposition(
            id: custom.id, name: custom.name,
            program: program, layers: existing.composition.layers,
            timeline: existing.composition.timeline,
            deterministicSeed: 800)
        let local = try CreativePresetPackage(
            id: custom.id, name: custom.name, author: "Creator",
            composition: composition)
        try await store.save(local)
        let all = await CreativePresetCatalog.availableExperiences(from: store)
        let ids: [String] = all.map { $0.id }
        // Presence, not a fixed count: recipes first, the three original
        // experiences, any newer curated ones, then local packages last.
        XCTAssertEqual(Array(ids.prefix(4)), ["original", "bass-pulse", "night-drive", "soft-flow"])
        for id in ["cyber-night", "liquid-dream", "neon-pulse"] {
            XCTAssertTrue(ids.contains(id), id)
        }
        for curated in CreativePresetCatalog.experiencePresets {
            XCTAssertTrue(ids.contains(curated.id), curated.id)
        }
        XCTAssertEqual(Set(ids).count, ids.count, "No duplicated identities")
        XCTAssertEqual(ids.last, "local-experience")
        XCTAssertEqual(all.last?.package, local)
        XCTAssertFalse(all.last?.audioMapping.enabled ?? true)
    }

    func testAudioIntensityRemainsFiniteWithoutRealTimeOrRenderers() throws {
        let preset = try selected("neon-pulse")
        for index in 0..<50 {
            let time = Double(index) / 10
            let features = audio(bass: Double(index) / 40,
                                 energy: Double(index) / 35,
                                 treble: Double(index) / 25,
                                 beat: index % 3 == 0)
            let frame = try XCTUnwrap(CreativeExperienceResolver.resolve(
                preset, elapsed: time, features: features,
                typography: lyricLayer()))
            XCTAssertTrue((0...1).contains(frame.visualFrame.intensity))
            XCTAssertTrue((0...1).contains(frame.visualFrame.movement))
            XCTAssertTrue((0...1).contains(frame.audioState.typographyIntensity))
            XCTAssertEqual(frame.visualFrame.parameters,
                           frame.compositionFrame.programParameters)
        }
    }
}
