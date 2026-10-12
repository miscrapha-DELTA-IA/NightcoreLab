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
    var materialFrame: MaterialFrame? = nil

    func withMaterial(_ frame: MaterialFrame) -> ResolvedCompositionFrame {
        var copy = self
        copy.materialFrame = frame
        return copy
    }

    func withTypography(_ frame: TypographyFrame?) -> ResolvedCompositionFrame {
        ResolvedCompositionFrame(
            compositionID: compositionID, timestamp: timestamp,
            deterministicSeed: deterministicSeed,
            programParameters: programParameters, layers: layers,
            typographyFrame: frame, materialFrame: materialFrame)
    }
}

// MARK: - Story pixel binding (ported from Stage 10A; no new model or renderer)

/// Story-space values for one layer kind. Pure, so preview and export apply
/// exactly the same numbers.
struct StoryLayerModifiers: Equatable, Sendable {
    let opacity: Double
    let scale: Double
    /// Points on the 540 × 960 Story canvas.
    let offsetX: Double
    let offsetY: Double
    /// Radians.
    let rotation: Double

    static let identity = StoryLayerModifiers(opacity: 1, scale: 1, offsetX: 0,
                                              offsetY: 0, rotation: 0)

    var isIdentity: Bool { self == .identity }
}

extension ResolvedLayerFrame {
    /// The first layer of `kind` drives that Story element. Without a
    /// composition frame (legacy direct requests) nothing changes; with one,
    /// a missing/inactive layer hides its element. `intensity` is reserved.
    static func storyModifiers(kind: PresetLayerKind,
                               frame: ResolvedCompositionFrame?) -> StoryLayerModifiers {
        guard let frame else { return .identity }
        guard let layer = frame.layers.first(where: { $0.kind == kind }) else {
            return StoryLayerModifiers(opacity: 0, scale: 1, offsetX: 0, offsetY: 0, rotation: 0)
        }
        return StoryLayerModifiers(
            opacity: layer.value(for: .opacity),
            scale: layer.value(for: .scale),
            offsetX: layer.value(for: .offsetX) * Double(StoryVideoRequest.size.width),
            offsetY: layer.value(for: .offsetY) * Double(StoryVideoRequest.size.height),
            rotation: layer.value(for: .rotation))
    }
}
