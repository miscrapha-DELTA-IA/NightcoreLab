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
}
