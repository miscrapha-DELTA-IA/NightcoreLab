import Foundation
import SwiftUI
import UIKit
import CoreGraphics
import XCTest
@testable import NightcoreLab

/// Frozen copy of pre-10A CompositionFrameResolver; intentionally retains
/// validation, per-frame sorting and keyframe filtering for a strict oracle.
/// Deterministic pure function of composition, elapsed timestamp and a
/// frozen audio sample. No clocks, random, persistent state, UI, audio graph
/// or rendering. Both preview and future export can call exactly this path.
private enum LegacyCompositionFrameResolver {
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

    /// Keyframes are authored in VIDEO elapsed seconds, not audio seconds.
    /// At/before the first key the first value holds; after the last the last
    /// value holds. The destination key's easing drives the incoming segment.
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


final class StoryRuntimeWiringTests: XCTestCase {
    private func baseProgram() -> CreativeVisualProgram {
        CreativePresetCatalog.effectiveProgram(
            id: "bass-pulse", theme: .acid, typography: .neon,
            background: .turbulent, reaction: .responsive)
    }

    private func complexComposition() throws -> VisualComposition {
        let timeline = try CompositionTimeline(
            sourceStart: 1.75, playbackSpeed: 1.25, duration: 10)
        let easing: [CompositionEasing] = [.hold, .linear, .easeInOut]
        let layers = PresetLayerKind.allCases.enumerated().map { index, kind -> PresetLayer in
            let keyframes = LayerProperty.allCases.flatMap { property in
                [0.0, 1.5, 3.8, 5.5, 8.75].enumerated().map { key, time in
                    let lo = property.bounds.lowerBound
                    let hi = property.bounds.upperBound
                    let fraction = Double(((index + 3) * (key + 7) +
                                           property.rawValue.utf8.count * 13) % 89) / 90
                    return CompositionKeyframe(
                        timestamp: time, property: property,
                        value: lo + fraction * (hi - lo),
                        easing: easing[(key + index) % easing.count])
                }
            }
            let bindings = LayerProperty.allCases.enumerated().map { j, property in
                LayerAudioBinding(property: property, equation: CreativeEquation(
                    signal: [CreativeSignal.bass, .energy, .beat, .treble,
                             .timeSine, .mid][j],
                    operation: [.add, .multiply, .replace][j % 3],
                    gain: 0.3, bias: 0.05, frequency: 0.4))
            }
            let clip: CompositionClip? = {
                if index == 1 { return CompositionClip(start: 1, end: 7) }
                if index == 3 { return CompositionClip(start: 2.5, end: 9.5) }
                return nil
            }()
            return PresetLayer(
                id: kind.rawValue, kind: kind, zIndex: index * 10,
                activeRange: clip,
                bindings: bindings, keyframes: Array(keyframes.reversed()))
        }
        return try VisualComposition(
            id: "bass-pulse", name: "Compiled Test",
            program: baseProgram(), layers: layers,
            timeline: timeline, deterministicSeed: 0xABCD)
    }

    private func signal(_ i: Int) -> AudioFeatures? {
        guard i % 11 != 0 else { return nil }
        return AudioFeatures(
            bass: Double(i % 17) / 16,
            mid: Double(i % 13) / 12,
            treble: Double(i % 19) / 18,
            energy: Double(i % 23) / 22,
            beatDetected: i % 7 == 0)
    }

    func testCompiledRuntimeMatchesFrozenReferenceFor600Timestamps() throws {
        let composition = try complexComposition()
        let runtime = CompositionRuntime(composition: composition)
        for index in 0..<600 {
            let elapsed = Double(index) / 60
            let source = signal(index)
            let expected = LegacyCompositionFrameResolver.resolve(
                composition, elapsed: elapsed, features: source)
            let actual = runtime.frame(at: elapsed, features: source)
            XCTAssertEqual(actual, expected, "index=\(index)")
            XCTAssertEqual(CompositionFrameResolver.resolve(
                composition, elapsed: elapsed, features: source), expected)
        }
        for t in [0, 1, 1.5, 2.5, 3.8, 5.5, 7, 8.75, 9.5, 10] {
            XCTAssertEqual(runtime.frame(at: t, features: signal(42)),
                LegacyCompositionFrameResolver.resolve(
                    composition, elapsed: t, features: signal(42)))
        }
        XCTAssertNil(runtime.frame(at: .nan, features: nil))
        XCTAssertNil(runtime.frame(at: 11, features: nil))
    }

    func testLayerCanvasMappingAndInactiveOpacityArePure() throws {
        let comp = try complexComposition()
        let runtime = CompositionRuntime(composition: comp)
        let frame = try XCTUnwrap(runtime.frame(at: 0, features: .silent))
        let missing = ResolvedLayerFrame.storyModifiers(
            kind: .overlay, frame: frame)
        XCTAssertEqual(missing.opacity, 0)
        XCTAssertFalse(missing.isIdentity)
        let noComposition = ResolvedLayerFrame.storyModifiers(
            kind: .overlay, frame: nil)
        XCTAssertEqual(noComposition.opacity, 1)
        XCTAssertTrue(noComposition.isIdentity)
        let artwork = ResolvedLayerFrame.storyModifiers(
            kind: .artwork, frame: frame)
        XCTAssertTrue(artwork.offsetX.isFinite)
        XCTAssertTrue(artwork.offsetY.isFinite)
        XCTAssertLessThanOrEqual(abs(artwork.offsetX), 540)
        XCTAssertLessThanOrEqual(abs(artwork.offsetY), 960)
    }

    func testMeasureCompiled1000Frames() throws {
        let composition = try complexComposition()
        let runtime = CompositionRuntime(composition: composition)
        var checksum = 0.0
        measure {
            for index in 0..<1000 {
                let frame = runtime.frame(at: Double(index % 600) / 60,
                                          features: signal(index))
                checksum += frame?.layers.first?.value(for: .scale) ?? 0
            }
        }
        XCTAssertGreaterThan(checksum, 0)
    }

    func testMeasureReference1000Frames() throws {
        let composition = try complexComposition()
        var checksum = 0.0
        measure {
            for index in 0..<1000 {
                let frame = LegacyCompositionFrameResolver.resolve(
                    composition, elapsed: Double(index % 600) / 60,
                    features: signal(index))
                checksum += frame?.layers.first?.value(for: .scale) ?? 0
            }
        }
        XCTAssertGreaterThan(checksum, 0)
    }
}
