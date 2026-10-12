import Foundation

/// A VisualComposition prepared once for repeated frame queries (Stage 10C).
///
/// The resolver used to revalidate the whole composition, sort the layers and
/// filter + sort every keyframe track on EVERY frame. These derived values only
/// depend on the immutable composition, so they are computed here once and
/// reused by preview scrubbing and every exported frame. Pure data: no clock,
/// RNG, UI, audio graph or renderer.
struct CompiledComposition: Sendable {
    struct Layer: Sendable {
        let source: PresetLayer
        /// Keyframes per property, sorted by timestamp (duplicates are
        /// rejected by PresetLayer.isValid, so the order is unique).
        let tracks: [LayerProperty: [CompositionKeyframe]]
        /// First binding per property, matching the former `first(where:)`.
        let bindings: [LayerProperty: LayerAudioBinding]
    }

    /// Validated once. VisualComposition can only be built through its
    /// throwing initializer, but the guard keeps the old contract exact.
    let isValid: Bool
    /// Back-to-front: lowest zIndex first, stable id tie-break.
    let layers: [Layer]

    init(_ composition: VisualComposition) {
        isValid = composition.isValid
        layers = composition.orderedLayers.map { layer in
            var tracks: [LayerProperty: [CompositionKeyframe]] = [:]
            for property in LayerProperty.allCases {
                let points = layer.keyframes.filter { $0.property == property }
                    .sorted { $0.timestamp < $1.timestamp }
                if !points.isEmpty { tracks[property] = points }
            }
            var bindings: [LayerProperty: LayerAudioBinding] = [:]
            for binding in layer.bindings where bindings[binding.property] == nil {
                bindings[binding.property] = binding
            }
            return Layer(source: layer, tracks: tracks, bindings: bindings)
        }
    }
}

/// Deterministic pure function of composition, elapsed timestamp and a
/// frozen audio sample. No clocks, random, persistent state, UI, audio graph
/// or rendering. Both preview and export call exactly this path.
enum CompositionFrameResolver {
    /// Source-compatible entry point. Compiles on every call; hot paths keep a
    /// CompositionRuntime (which compiles once) instead.
    static func resolve(_ composition: VisualComposition,
                        elapsed: TimeInterval,
                        features: AudioFeatures? = nil) -> ResolvedCompositionFrame? {
        CompositionRuntime(composition: composition).frame(at: elapsed, features: features)
    }

    static func resolve(_ compiled: CompiledComposition,
                        of composition: VisualComposition,
                        elapsed: TimeInterval,
                        features: AudioFeatures?) -> ResolvedCompositionFrame? {
        guard compiled.isValid,
              let timestamp = composition.timeline.timestamp(at: elapsed) else {
            return nil
        }

        let source = features ?? .silent
        let response = AudioVisualMapper.map(source, preset: composition.program.preset)
        let programFrame = CreativeParameterResolver.resolve(
            program: composition.program,
            response: response, features: source,
            sourceTime: timestamp.sourceTime)

        let resolvedLayers: [ResolvedLayerFrame] = compiled.layers
            .filter { $0.source.isActive(at: timestamp.elapsed) }
            .map { layer in
                var values: [LayerProperty: Double] = [:]
                for property in LayerProperty.allCases {
                    let authored = layer.source.properties[property] ?? property.defaultValue
                    let animated = keyframed(layer.tracks[property],
                                             elapsed: timestamp.elapsed) ?? authored
                    if let binding = layer.bindings[property], features != nil {
                        values[property] = binding.apply(
                            to: animated, features: source,
                            sourceTime: timestamp.sourceTime,
                            reaction: composition.program.preset.audioReaction)
                    } else {
                        values[property] = property.clamped(animated)
                    }
                }
                return ResolvedLayerFrame(id: layer.source.id, kind: layer.source.kind,
                                          zIndex: layer.source.zIndex, values: values)
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
    /// `points` must already be sorted by timestamp (see CompiledComposition).
    private static func keyframed(_ points: [CompositionKeyframe]?,
                                  elapsed: TimeInterval) -> Double? {
        guard let points, let first = points.first else { return nil }
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
