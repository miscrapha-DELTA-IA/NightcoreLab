import Foundation

/// Pure frame data; renderers may consume it in a future stage.
struct ResolvedLayerFrame: Equatable, Sendable, Identifiable {
    let id: String
    let kind: PresetLayerKind
    let zIndex: Int
    let values: [LayerProperty: Double]

    func value(for property: LayerProperty) -> Double {
        values[property] ?? property.defaultValue
    }
}

struct ResolvedCompositionFrame: Equatable, Sendable {
    let compositionID: String
    let timestamp: CompositionTimestamp
    let deterministicSeed: UInt64
    /// Reuses the existing projectM-style CreativeParameterResolver output.
    let programParameters: CreativeParameterFrame
    /// Sorted back-to-front: lowest zIndex first, stable id tie-break.
    let layers: [ResolvedLayerFrame]
    /// Optional, independent lyric result for the active typography layer.
    let typographyFrame: TypographyFrame?

    func withTypography(_ frame: TypographyFrame?) -> ResolvedCompositionFrame {
        ResolvedCompositionFrame(
            compositionID: compositionID, timestamp: timestamp,
            deterministicSeed: deterministicSeed,
            programParameters: programParameters, layers: layers,
            typographyFrame: frame)
    }
}


// MARK: - Stage 10A Story pixel binding (no new models or drawing engines)

extension ResolvedLayerFrame {
    /// Pure Story-space mapping. Off-range/missing layers are hidden ONLY when
    /// a composition frame exists; nil frame is the old direct-request path.
    /// Intensity remains reserved/unrendered.
    static func storyModifiers(kind: PresetLayerKind,
                               frame: ResolvedCompositionFrame?)
        -> (opacity: Double, scale: Double, offsetX: Double,
            offsetY: Double, rotation: Double, isIdentity: Bool) {
        let layer = frame?.layers.first(where: { $0.kind == kind })
        let opacity = layer?.value(for: .opacity) ??
            (frame == nil ? LayerProperty.opacity.defaultValue : 0)
        let scale = layer?.value(for: .scale) ?? LayerProperty.scale.defaultValue
        let offsetX = (layer?.value(for: .offsetX) ??
            LayerProperty.offsetX.defaultValue) * Double(StoryVideoRequest.size.width)
        let offsetY = (layer?.value(for: .offsetY) ??
            LayerProperty.offsetY.defaultValue) * Double(StoryVideoRequest.size.height)
        let rotation = layer?.value(for: .rotation) ??
            LayerProperty.rotation.defaultValue
        return (opacity, scale, offsetX, offsetY, rotation,
                opacity == 1 && scale == 1 && offsetX == 0 &&
                offsetY == 0 && rotation == 0)
    }
}
