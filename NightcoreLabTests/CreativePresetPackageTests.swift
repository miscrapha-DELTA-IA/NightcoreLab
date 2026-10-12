import Foundation
import XCTest
@testable import NightcoreLab

final class CreativePresetPackageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("authoring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func package(
        id: String = "my-neon",
        program: CreativeVisualProgram? = nil,
        seed: UInt64 = 999
    ) throws -> CreativePresetPackage {
        let recipe = program ?? CreativePresetCatalog.program(for: "bass-pulse")
        let original = recipe.preset
        let named = CreativePreset(
            id: id, name: "My Neon", theme: original.theme,
            typographyStyle: original.typographyStyle,
            visualStyle: original.visualStyle,
            audioReaction: original.audioReaction)
        let renamed = CreativeVisualProgram(preset: named, rules: recipe.rules)
        let timeline = try CompositionTimeline(
            sourceStart: 10, playbackSpeed: 1.5, duration: 12)
        let composition = try CreativeSnapshotAdapter.wrap(
            renamed, timeline: timeline, deterministicSeed: seed)
        return try CreativePresetPackage(
            id: id, name: "My Neon", author: "Local Creator",
            composition: composition,
            previewMetadata: .init(
                description: "A reusable visual composition",
                previewElapsed: 3, canvasHint: .portrait))
    }

    func testCompletePackageCodableRoundTripAndAudioReference() throws {
        let source = try package()
        let encoded = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(
            CreativePresetPackage.self, from: encoded)
        XCTAssertEqual(decoded, source)
        XCTAssertTrue(decoded.isValid)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.visualPreset,
                       source.composition.program.preset.visualStyle)
        XCTAssertEqual(decoded.typographyPreset.style, .neon)
        XCTAssertEqual(decoded.audioMapping.signals, [.bass])
        XCTAssertTrue(decoded.audioMapping.hasProgramRules)
        XCTAssertFalse(decoded.audioMapping.hasLayerBindings)
        XCTAssertEqual(decoded.composition.deterministicSeed, 999)
        XCTAssertEqual(decoded.previewMetadata.previewElapsed, 3)
    }

    func testSchemaVersionIsStrictAndDoesNotChangeInnerSchemas() throws {
        let source = try package()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(source)) as? [String: Any])
        json["schemaVersion"] = 2
        XCTAssertThrowsError(try JSONDecoder().decode(
            CreativePresetPackage.self,
            from: JSONSerialization.data(withJSONObject: json)))
        XCTAssertEqual(source.composition.schemaVersion,
                       VisualComposition.supportedSchema)
        XCTAssertEqual(source.composition.program.schemaVersion,
                       CreativeVisualProgram.supportedSchema)
    }

    func testLegacyCatalogPresetsRemainUntouchedAndPortable() throws {
        for name in ["original", "bass-pulse", "night-drive", "soft-flow"] {
            let existing = CreativePresetCatalog.program(for: name)
            let wrapped = try XCTUnwrap(CreativePresetCatalog.builtInPackage(for: name))
            XCTAssertEqual(wrapped.id, name)
            XCTAssertEqual(wrapped.composition.program, existing)
            XCTAssertEqual(wrapped.typographyPreset.legacyStyle,
                           existing.preset.typographyStyle)
            XCTAssertEqual(try JSONDecoder().decode(
                CreativePresetPackage.self,
                from: JSONEncoder().encode(wrapped)), wrapped)
            XCTAssertEqual(CreativePresetCatalog.program(for: name), existing)
        }
    }

    func testMissingDerivedFieldsUseCompositionInsteadOfInventingRules() throws {
        let source = try package()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(source)) as? [String: Any])
        json.removeValue(forKey: "visualPreset")
        json.removeValue(forKey: "typographyPreset")
        json.removeValue(forKey: "audioMapping")
        json.removeValue(forKey: "previewMetadata")
        let recovered = try JSONDecoder().decode(
            CreativePresetPackage.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(recovered.composition, source.composition)
        XCTAssertEqual(recovered.audioMapping, source.audioMapping)
        XCTAssertEqual(recovered.visualPreset, source.visualPreset)
        XCTAssertEqual(recovered.typographyPreset.style, .neon)
        XCTAssertEqual(recovered.previewMetadata.previewElapsed, 0)
    }

    func testMissingCompositionAndContradictoryMetadataAreRejected() throws {
        let source = try package()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(source)) as? [String: Any])
        json.removeValue(forKey: "composition")
        XCTAssertThrowsError(try JSONDecoder().decode(
            CreativePresetPackage.self,
            from: JSONSerialization.data(withJSONObject: json)))
        json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(source)) as? [String: Any])
        json["id"] = "not-the-composition-id"
        XCTAssertThrowsError(try JSONDecoder().decode(
            CreativePresetPackage.self,
            from: JSONSerialization.data(withJSONObject: json)))
        json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(source)) as? [String: Any])
        json["audioMapping"] = ["source": "embeddedComposition",
                               "signals": [], "hasProgramRules": false,
                               "hasLayerBindings": false] as [String: Any]
        XCTAssertThrowsError(try JSONDecoder().decode(
            CreativePresetPackage.self,
            from: JSONSerialization.data(withJSONObject: json)))
    }

    func testPackageHasDeterministicFrameEquivalentToEmbeddedProgram() throws {
        let source = try package()
        let decoded = try JSONDecoder().decode(
            CreativePresetPackage.self, from: JSONEncoder().encode(source))
        let sample = AudioFeatures(
            bass: 0.84, mid: 0.22, energy: 0.7, beatDetected: true)
        for elapsed in [0.0, 0.25, 2.75, 8.4, 12.0] {
            let first = try XCTUnwrap(CompositionFrameResolver.resolve(
                source.composition, elapsed: elapsed, features: sample))
            let second = try XCTUnwrap(CompositionFrameResolver.resolve(
                decoded.composition, elapsed: elapsed, features: sample))
            let repeated = try XCTUnwrap(CompositionFrameResolver.resolve(
                source.composition, elapsed: elapsed, features: sample))
            XCTAssertEqual(first, second)
            XCTAssertEqual(first, repeated)
            let direct = CreativeParameterResolver.resolve(
                program: source.composition.program,
                response: AudioVisualMapper.map(
                    sample, preset: source.composition.program.preset),
                features: sample, sourceTime: first.timestamp.sourceTime)
            XCTAssertEqual(first.programParameters, direct)
        }
    }

    func testAudioMappingReferencesProgramAndLayerSignalsWithoutDuplicatingEquations() throws {
        let baseline = CreativePresetCatalog.program(for: "bass-pulse")
        let original = baseline.preset
        let custom = CreativePreset(
            id: "both-sources", name: "Both Sources", theme: original.theme,
            typographyStyle: original.typographyStyle,
            visualStyle: original.visualStyle, audioReaction: original.audioReaction)
        let program = CreativeVisualProgram(preset: custom, rules: baseline.rules)
        let timeline = try CompositionTimeline(
            sourceStart: 0, playbackSpeed: 1, duration: 10)
        let layer = PresetLayer(id: "artwork", kind: .artwork, zIndex: 10,
            bindings: [LayerAudioBinding(property: .opacity,
                equation: CreativeEquation(signal: .mid))])
        let composition = try CreativeSnapshotAdapter.wrap(
            program, timeline: timeline, layers: [layer])
        let value = try CreativePresetPackage(
            id: "both-sources", name: "Both Sources", author: "Test",
            composition: composition)
        XCTAssertEqual(value.audioMapping.signals, [.bass, .mid])
        XCTAssertTrue(value.audioMapping.hasProgramRules)
        XCTAssertTrue(value.audioMapping.hasLayerBindings)
        XCTAssertEqual(value.audioMapping,
            CreativePresetAudioMapping.referencing(value.composition))
        XCTAssertEqual(try JSONDecoder().decode(
            CreativePresetPackage.self, from: JSONEncoder().encode(value)), value)
    }

    func testLocalStorePersistsUserPresetsAcrossReopenAndRemoves() async throws {
        let source = try package()
        let store = CreativePresetPackageStore(directory: directory)
        try await store.save(source)
        let reopened = CreativePresetPackageStore(directory: directory)
        let loaded = await reopened.load(id: source.id)
        XCTAssertEqual(loaded, source)
        let found = await reopened.userPackages()
        XCTAssertEqual(found, [source])
        try await reopened.delete(id: source.id)
        let missing = await reopened.load(id: source.id)
        XCTAssertNil(missing)
    }

    func testCannotOverwriteOrDeleteBuiltInPresets() async throws {
        let store = CreativePresetPackageStore(directory: directory)
        let builtIn = try XCTUnwrap(
            CreativePresetCatalog.builtInPackage(for: "original"))
        do {
            try await store.save(builtIn)
            XCTFail("Built-in name must be reserved")
        } catch CreativePresetPackageStore.StoreError.reservedID {}
        do {
            try await store.delete(id: "bass-pulse")
            XCTFail("Built-in packages cannot be deleted")
        } catch CreativePresetPackageStore.StoreError.reservedID {}
        XCTAssertEqual(CreativePresetCatalog.program(for: "original"),
                       builtIn.composition.program)
    }

    func testCatalogMergesLocalAndBuiltInsWithExplicitFallback() async throws {
        let store = CreativePresetPackageStore(directory: directory)
        let source = try package()
        try await store.save(source)
        let all = await CreativePresetCatalog.availablePackages(from: store)
        XCTAssertEqual(all.map(\.id),
                       ["original", "bass-pulse", "night-drive", "soft-flow", "my-neon"])
        let selected = await CreativePresetCatalog.resolvePackage(
            id: "my-neon", from: store)
        XCTAssertEqual(selected?.package, source)
        XCTAssertEqual(selected?.usedFallback, false)
        let unknown = await CreativePresetCatalog.resolvePackage(
            id: "unknown", from: store)
        XCTAssertEqual(unknown?.package.id, "original")
        XCTAssertEqual(unknown?.usedFallback, true)
        XCTAssertEqual(CreativePresetCatalog.program(for: "unknown").id, "original")
    }

    func testCorruptUserPackageCannotBreakCatalogAndFallsBackSafely() async throws {
        let source = try package()
        let store = CreativePresetPackageStore(directory: directory)
        try await store.save(source)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        let url = try XCTUnwrap(files.first)
        try Data(#"{"schemaVersion":1,"id":"my-neon"}"#.utf8)
            .write(to: url, options: .atomic)
        let corrupt = await store.load(id: "my-neon")
        XCTAssertNil(corrupt)
        let available = await CreativePresetCatalog.availablePackages(from: store)
        XCTAssertEqual(available.count, 4)
        let fallback = await CreativePresetCatalog.resolvePackage(
            id: "my-neon", from: store)
        XCTAssertEqual(fallback?.package.id, "original")
        XCTAssertEqual(fallback?.usedFallback, true)
    }

    func testSnapshotCapturesFullRecipeAndCurrentClockWithoutExportChanges() throws {
        let source = try package()
        let preset = source.composition.program.preset
        let snapshot = CreativeSnapshot(
            track: nil, theme: preset.theme, preset: preset,
            visualState: .init(playbackTime: 18, marblePhase: 3, isPlaying: true),
            capturedAt: Date(timeIntervalSince1970: 0))
        let frozen = try CreativePresetPackageSnapshot.capture(
            snapshot, package: source, duration: 8, playbackSpeed: 1.25)
        XCTAssertEqual(frozen.package.composition.program, source.composition.program)
        XCTAssertEqual(frozen.package.composition.layers, source.composition.layers)
        XCTAssertEqual(frozen.package.composition.deterministicSeed, 999)
        XCTAssertEqual(frozen.package.composition.timeline.sourceStart, 18)
        XCTAssertEqual(frozen.package.composition.timeline.playbackSpeed, 1.25)
        XCTAssertEqual(frozen.package.author, "Local Creator")
        let features = AudioFeatures(bass: 0.6, energy: 0.75)
        XCTAssertEqual(frozen.frame(at: 3, features: features),
            CompositionFrameResolver.resolve(
                frozen.package.composition, elapsed: 3, features: features))
        let mismatched = CreativeSnapshot(
            track: nil, theme: preset.theme,
            preset: CreativePresetCatalog.program(for: "soft-flow").preset,
            visualState: snapshot.visualState, capturedAt: snapshot.capturedAt)
        XCTAssertThrowsError(try CreativePresetPackageSnapshot.capture(
            mismatched, package: source, duration: 8))
    }

    func testOversizedPackageIsRejectedAndInvalidFilesAreNotDeleted() async throws {
        let source = try package()
        let tiny = CreativePresetPackageStore(directory: directory, maximumBytes: 100)
        do {
            try await tiny.save(source)
            XCTFail("Storage cap must be enforced")
        } catch CreativePresetPackageStore.StoreError.packageTooLarge {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil).isEmpty)
    }
}
