import Foundation

/// Source-time feature sampler shared by preview and export. Preserves the
/// Marble's fixed 150 ms onset look-back without adding another FFT.
enum CompositionAudioSampler {
    static func sample(_ timeline: AudioFeatureTimeline?,
                       at sourceTime: TimeInterval) -> AudioFeatures? {
        guard let timeline, sourceTime.isFinite,
              sourceTime >= 0, sourceTime <= timeline.duration else { return nil }
        let frame = timeline.features(at: sourceTime)
        let onsets = timeline.beatCount(
            after: max(0, sourceTime - 0.15), through: sourceTime)
        return AudioFeatures(
            bass: frame.bass, mid: frame.mid, treble: frame.treble,
            energy: frame.energy, beatDetected: onsets > 0)
    }
}

/// Immutable compiled form of the *existing* composition. No new preset,
/// renderer, animation engine, clock or global mutable frame cache.
struct CompositionRuntime: Sendable {
    let composition: VisualComposition

    private struct CompiledLayer: Sendable {
        let layer: PresetLayer
        let tracks: [LayerProperty: [CompositionKeyframe]]
        let bindings: [LayerProperty: LayerAudioBinding]

        init(_ layer: PresetLayer) {
            self.layer = layer
            self.tracks = Dictionary(
                grouping: layer.keyframes, by: \.property
            ).mapValues { $0.sorted { $0.timestamp < $1.timestamp } }
            self.bindings = Dictionary(
                uniqueKeysWithValues: layer.bindings.map { ($0.property, $0) })
        }

        /// Incoming key's easing drives the segment, exactly as Stage 5A.
        func keyframed(_ property: LayerProperty, elapsed: TimeInterval) -> Double? {
            guard let points = tracks[property], let first = points.first else { return nil }
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

    private let compiledLayers: [CompiledLayer]
    private let preparedLines: [Int: TypographyPreparedLine]

    init(composition: VisualComposition, lyrics: [TimedLyricLine] = []) {
        self.composition = composition
        // VisualComposition's validating init/decoder guarantees correct layer
        // uniqueness and valid keyframes. This cost is paid ONCE per request.
        self.compiledLayers = composition.orderedLayers.map(CompiledLayer.init)
        self.preparedLines = Dictionary(
            lyrics.map { ($0.id, TypographyPreparedLine($0)) },
            uniquingKeysWith: { _, newest in newest })
    }

    /// Pure evaluation of the compiled plan. No validation/sorting/filtering
    /// on every exported frame. Output matches the legacy resolver bit-for-bit.
    func frame(at elapsed: TimeInterval,
               features: AudioFeatures?) -> ResolvedCompositionFrame? {
        guard let timestamp = composition.timeline.timestamp(at: elapsed) else { return nil }
        let source = features ?? .silent
        let response = AudioVisualMapper.map(source, preset: composition.program.preset)
        let programFrame = CreativeParameterResolver.resolve(
            program: composition.program, response: response,
            features: source, sourceTime: timestamp.sourceTime)
        let resolvedLayers: [ResolvedLayerFrame] = compiledLayers
            .filter { $0.layer.isActive(at: timestamp.elapsed) }
            .map { compiled in
                let layer = compiled.layer
                var values: [LayerProperty: Double] = [:]
                for property in LayerProperty.allCases {
                    let authored = layer.properties[property] ?? property.defaultValue
                    let animated = compiled.keyframed(property, elapsed: timestamp.elapsed)
                        ?? authored
                    if let binding = compiled.bindings[property], features != nil {
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
            compositionID: composition.id, timestamp: timestamp,
            deterministicSeed: composition.deterministicSeed,
            programParameters: programFrame, layers: resolvedLayers,
            typographyFrame: nil)
    }

    func frame(at elapsed: TimeInterval,
               features: AudioFeatures?,
               typography: TypographyLayer?) -> ResolvedCompositionFrame? {
        guard let base = frame(at: elapsed, features: features) else { return nil }
        guard let typography,
              base.layers.contains(where: {
                  $0.id == typography.layerID && $0.kind == .typography
              }) else { return base }
        let lyricTime = base.timestamp.sourceTime + typography.lyricOffset
        guard lyricTime.isFinite else { return base }
        return base.withTypography(TypographyResolver.resolve(
            typography.state, at: lyricTime, features: features,
            preset: typography.preset,
            prepared: preparedLines[typography.state.line.id]))
    }

    func frame(at elapsed: TimeInterval,
               audioTimeline: AudioFeatureTimeline?,
               typography: TypographyLayer? = nil) -> ResolvedCompositionFrame? {
        guard let timestamp = composition.timeline.timestamp(at: elapsed) else {
            return nil
        }
        let features = CompositionAudioSampler.sample(
            audioTimeline, at: timestamp.sourceTime)
        return frame(at: elapsed, features: features, typography: typography)
    }

    func experienceFrame(at elapsed: TimeInterval,
                         preset: CreativeExperiencePreset,
                         features: AudioFeatures? = nil,
                         typography: TypographyLayer? = nil) -> CreativeExperienceFrame? {
        guard preset.composition == composition else { return nil }
        return CreativeExperienceResolver.resolve(
            preset, elapsed: elapsed, features: features, typography: typography)
    }

    static func freeze(program: CreativeVisualProgram?,
                       sourceStart: TimeInterval, speed: Double,
                       duration: TimeInterval) -> VisualComposition? {
        guard let program,
              let timeline = try? CompositionTimeline(
                sourceStart: sourceStart, playbackSpeed: speed, duration: duration) else {
            return nil
        }
        return try? CreativeSnapshotAdapter.wrap(program, timeline: timeline)
    }
}
