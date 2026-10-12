import Foundation

/// Deterministic pure function of composition, elapsed timestamp and a
/// frozen audio sample. No clocks, random, persistent state, UI, audio graph
/// or rendering. Both preview and future export can call exactly this path.
enum CompositionFrameResolver {
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
            layers: resolvedLayers)
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
