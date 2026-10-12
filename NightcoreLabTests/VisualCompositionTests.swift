import Foundation
import XCTest
@testable import NightcoreLab

final class VisualCompositionTests: XCTestCase {
    private func timeline(speed: Double = 1.0) throws -> CompositionTimeline {
        try CompositionTimeline(sourceStart: 12, playbackSpeed: speed, duration: 10)
    }

    private func composition(
        id: String = "original",
        layers: [PresetLayer] = PresetLayer.defaultLayers,
        speed: Double = 1
    ) throws -> VisualComposition {
        try CreativeSnapshotAdapter.wrap(
            CreativePresetCatalog.program(for: id),
            timeline: timeline(speed: speed),
            layers: layers, deterministicSeed: 42)
    }

    private var audio: AudioFeatures {
        AudioFeatures(bass: 0.8, mid: 0.3, treble: 0.2,
                      energy: 0.65, beatDetected: true)
    }

    func testCodableRoundTripKeepsAllCompositionMetadataAndRules() throws {
        for id in ["original", "bass-pulse", "night-drive", "soft-flow"] {
            let original = try composition(id: id)
            let data = try JSONEncoder().encode(original)
            let reopened = try JSONDecoder().decode(VisualComposition.self, from: data)
            XCTAssertEqual(original, reopened)
            XCTAssertEqual(reopened.schemaVersion, VisualComposition.supportedSchema)
            XCTAssertEqual(reopened.program, CreativePresetCatalog.program(for: id))
            XCTAssertEqual(reopened.deterministicSeed, 42)
            XCTAssertEqual(reopened.layers.count, 4)
        }
    }

    func testUnsupportedSchemaAndArbitraryPropertiesAreRejected() throws {
        let item = try composition()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(item)) as? [String: Any])
        json["schemaVersion"] = 987
        XCTAssertThrowsError(try JSONDecoder().decode(VisualComposition.self,
            from: JSONSerialization.data(withJSONObject: json)))

        let layer = PresetLayer(id: "bad", kind: .overlay, zIndex: 0,
                                properties: [.opacity: 2])
        XCTAssertThrowsError(try VisualComposition(
            id: "bad", name: "Bad", program: item.program,
            layers: [layer], timeline: item.timeline))
        XCTAssertThrowsError(try JSONDecoder().decode(
            LayerAudioBinding.self,
            from: Data(#"{"property":"shader.random","equation":{}}"#.utf8)))
    }

    func testLayerOrderIsStableAcrossInputPermutations() throws {
        let a = PresetLayer(id: "b", kind: .typography, zIndex: 9)
        let b = PresetLayer(id: "a", kind: .artwork, zIndex: 9)
        let c = PresetLayer(id: "behind", kind: .background, zIndex: 1)
        let first = try composition(layers: [a, b, c])
        let second = try composition(layers: [c, a, b])
        XCTAssertEqual(first.orderedLayers.map(\.id), ["behind", "a", "b"])
        let x = try XCTUnwrap(CompositionFrameResolver.resolve(first, elapsed: 1))
        let y = try XCTUnwrap(CompositionFrameResolver.resolve(second, elapsed: 1))
        XCTAssertEqual(x, y)
    }

    func testSilenceAndMissingAudioKeepProgramNeutral() throws {
        let comp = try composition(id: "bass-pulse")
        let withoutAudio = try XCTUnwrap(CompositionFrameResolver.resolve(comp, elapsed: 2))
        let withSilence = try XCTUnwrap(CompositionFrameResolver.resolve(
            comp, elapsed: 2, features: .silent))
        XCTAssertEqual(withoutAudio.programParameters, .neutral)
        XCTAssertEqual(withSilence.programParameters, .neutral)
        XCTAssertEqual(withoutAudio.layers, withSilence.layers)
    }

    func testSameTimestampAudioAndPresetProduceSameFrame() throws {
        let comp = try composition(id: "night-drive")
        let first = try XCTUnwrap(CompositionFrameResolver.resolve(
            comp, elapsed: 4.25, features: audio))
        let later = try XCTUnwrap(CompositionFrameResolver.resolve(
            comp, elapsed: 8.5, features: audio))
        let again = try XCTUnwrap(CompositionFrameResolver.resolve(
            comp, elapsed: 4.25, features: audio))
        XCTAssertEqual(first, again)
        XCTAssertNotEqual(first.timestamp, later.timestamp)
        XCTAssertEqual(first.deterministicSeed, 42)
        XCTAssertEqual(first.timestamp.sourceTime, 16.25, accuracy: 0.00001)
    }

    func testSpeedChangesSourceTimeButNotElapsedKeyframes() throws {
        let layer = PresetLayer(id: "text", kind: .typography, zIndex: 1,
            keyframes: [
                CompositionKeyframe(timestamp: 0, property: .opacity, value: 0),
                CompositionKeyframe(timestamp: 10, property: .opacity, value: 1)
            ])
        let original = try composition(layers: [layer], speed: 1)
        let accelerated = try composition(layers: [layer], speed: 1.5)
        let ordinary = try XCTUnwrap(CompositionFrameResolver.resolve(
            original, elapsed: 4, features: audio))
        let faster = try XCTUnwrap(CompositionFrameResolver.resolve(
            accelerated, elapsed: 4, features: audio))
        XCTAssertEqual(ordinary.timestamp.elapsed, 4)
        XCTAssertEqual(faster.timestamp.elapsed, 4)
        XCTAssertEqual(ordinary.timestamp.sourceTime, 16, accuracy: 0.00001)
        XCTAssertEqual(faster.timestamp.sourceTime, 18, accuracy: 0.00001)
        XCTAssertEqual(ordinary.layers[0].value(for: .opacity), 0.4, accuracy: 0.00001)
        XCTAssertEqual(faster.layers[0].value(for: .opacity), 0.4, accuracy: 0.00001)
        XCTAssertNil(original.timeline.timestamp(at: 11))
        XCTAssertNil(accelerated.timeline.timestamp(at: -.infinity))
    }

    func testLinearEaseInOutAndHoldKeyframesArePredictable() throws {
        let easing = PresetLayer(id: "fade", kind: .overlay, zIndex: 3,
            keyframes: [
                CompositionKeyframe(timestamp: 0, property: .opacity, value: 0),
                CompositionKeyframe(timestamp: 10, property: .opacity, value: 1,
                                    easing: .easeInOut)
            ])
        let hold = PresetLayer(id: "hold", kind: .artwork, zIndex: 1,
            keyframes: [
                CompositionKeyframe(timestamp: 0, property: .opacity, value: 0.25),
                CompositionKeyframe(timestamp: 10, property: .opacity, value: 0.75,
                                    easing: .hold)
            ])
        let comp = try composition(layers: [easing, hold])
        let quarter = try XCTUnwrap(CompositionFrameResolver.resolve(comp, elapsed: 2.5))
        let midpoint = try XCTUnwrap(CompositionFrameResolver.resolve(comp, elapsed: 5))
        let end = try XCTUnwrap(CompositionFrameResolver.resolve(comp, elapsed: 10))
        XCTAssertEqual(quarter.layers[1].value(for: .opacity), 0.15625, accuracy: 0.000001)
        XCTAssertEqual(midpoint.layers[1].value(for: .opacity), 0.5, accuracy: 0.000001)
        XCTAssertEqual(midpoint.layers[0].value(for: .opacity), 0.25, accuracy: 0.000001)
        XCTAssertEqual(end.layers[0].value(for: .opacity), 0.75, accuracy: 0.000001)
        XCTAssertEqual(end.layers[1].value(for: .opacity), 1.0, accuracy: 0.000001)
    }

    func testAudioBindingUsesTypedExistingEquationAndOffIsSafe() throws {
        let layer = PresetLayer(id: "cover", kind: .artwork, zIndex: 1,
            properties: [.opacity: 0.4],
            bindings: [LayerAudioBinding(property: .opacity,
                equation: CreativeEquation(signal: .bass,
                    operation: .add, gain: 0.5))])
        let on = try composition(layers: [layer])
        let active = try XCTUnwrap(CompositionFrameResolver.resolve(
            on, elapsed: 2, features: audio))
        XCTAssertEqual(active.layers[0].value(for: .opacity), 0.8, accuracy: 0.00001)
        let missing = try XCTUnwrap(CompositionFrameResolver.resolve(on, elapsed: 2))
        XCTAssertEqual(missing.layers[0].value(for: .opacity), 0.4, accuracy: 0.00001)

        let offPreset = CreativePreset(
            id: on.program.preset.id, name: on.program.preset.name,
            theme: on.program.preset.theme,
            typographyStyle: on.program.preset.typographyStyle,
            visualStyle: on.program.preset.visualStyle, audioReaction: .off)
        let disabled = try VisualComposition(
            id: "off", name: "Off", program: CreativeVisualProgram(preset: offPreset),
            layers: [layer], timeline: timeline())
        let still = try XCTUnwrap(CompositionFrameResolver.resolve(
            disabled, elapsed: 2, features: audio))
        XCTAssertEqual(still.layers[0].value(for: .opacity), 0.4, accuracy: 0.00001)
        XCTAssertEqual(still.programParameters, .neutral)
    }

    func testClipActivationAndInvalidDuplicateLayerIDs() throws {
        let clip = PresetLayer(id: "clip", kind: .typography, zIndex: 1,
                                activeRange: .init(start: 2, end: 7))
        let comp = try composition(layers: [clip])
        XCTAssertTrue(try XCTUnwrap(CompositionFrameResolver.resolve(
            comp, elapsed: 3)).layers.count == 1)
        XCTAssertTrue(try XCTUnwrap(CompositionFrameResolver.resolve(
            comp, elapsed: 7)).layers.isEmpty)
        XCTAssertThrowsError(try composition(layers: [clip, clip]))
        let invalidRange = PresetLayer(id: "bad", kind: .overlay, zIndex: 1,
                                       activeRange: .init(start: 0, end: 50))
        XCTAssertThrowsError(try composition(layers: [invalidRange]))
    }

    func testFourExistingPresetsResolveUsingUnchangedParameterResolver() throws {
        for program in CreativePresetCatalog.all {
            let comp = try CreativeSnapshotAdapter.wrap(
                program, timeline: timeline())
            let resolved = try XCTUnwrap(CompositionFrameResolver.resolve(
                comp, elapsed: 2.5, features: audio))
            let expected = CreativeParameterResolver.resolve(
                program: program,
                response: AudioVisualMapper.map(audio, preset: program.preset),
                features: audio, sourceTime: 14.5)
            XCTAssertEqual(resolved.programParameters, expected, program.id)
        }
    }

    func testSnapshotAdapterPreservesCompleteProgramAndRejectsMismatch() throws {
        let program = CreativePresetCatalog.program(for: "bass-pulse")
        let snapshot = CreativeSnapshot(
            track: nil, theme: program.preset.theme,
            preset: program.preset,
            visualState: .init(playbackTime: 15, marblePhase: 2, isPlaying: true),
            capturedAt: Date(timeIntervalSince1970: 0))
        let frozen = try CreativeSnapshotAdapter.freeze(
            snapshot, program: program, duration: 8, playbackSpeed: 1.25,
            deterministicSeed: 101)
        XCTAssertEqual(frozen.program, program)
        XCTAssertEqual(frozen.program.rules, program.rules)
        XCTAssertEqual(frozen.layers.map(\.id),
                       ["background", "artwork", "typography", "overlay"])
        XCTAssertEqual(frozen.timeline.timestamp(at: 4)?.sourceTime, 20)
        XCTAssertEqual(frozen.deterministicSeed, 101)
        XCTAssertThrowsError(try CreativeSnapshotAdapter.freeze(
            snapshot, program: CreativePresetCatalog.program(for: "night-drive"),
            duration: 8))
    }

    func testFrameTimeRejectsInvalidInputsAndMultipleKeyframesForSameTime() throws {
        let comp = try composition()
        XCTAssertNil(CompositionFrameResolver.resolve(comp, elapsed: .nan))
        XCTAssertNil(CompositionFrameResolver.resolve(comp, elapsed: -1))
        XCTAssertThrowsError(try CompositionTimeline(
            sourceStart: 0, playbackSpeed: 0, duration: 10))
        let repeated = PresetLayer(id: "duplicate", kind: .overlay, zIndex: 1,
            keyframes: [
                CompositionKeyframe(timestamp: 4, property: .opacity, value: 0.2),
                CompositionKeyframe(timestamp: 4, property: .opacity, value: 0.5)
            ])
        XCTAssertThrowsError(try composition(layers: [repeated]))
    }
}
