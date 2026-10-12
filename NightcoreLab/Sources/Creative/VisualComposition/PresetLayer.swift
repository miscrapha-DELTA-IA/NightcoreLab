import Foundation

enum PresetLayerKind: String, Codable, CaseIterable, Sendable {
    case background, artwork, typography, overlay
}

/// An optional clip in elapsed video time. The end is exclusive.
struct CompositionClip: Codable, Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval

    var isValid: Bool { start.isFinite && end.isFinite && start >= 0 && end > start }
    func contains(_ elapsed: TimeInterval) -> Bool { elapsed >= start && elapsed < end }

    init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(start: try c.decode(Double.self, forKey: .start),
                  end: try c.decode(Double.self, forKey: .end))
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Invalid layer clip"))
        }
    }
}

/// Data only. No matching UIKit/SwiftUI/Metal layer is constructed in Stage 5A.
struct PresetLayer: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let kind: PresetLayerKind
    let zIndex: Int
    let activeRange: CompositionClip?
    let properties: [LayerProperty: Double]
    let bindings: [LayerAudioBinding]
    let keyframes: [CompositionKeyframe]

    init(id: String, kind: PresetLayerKind, zIndex: Int,
         activeRange: CompositionClip? = nil,
         properties: [LayerProperty: Double] = [:],
         bindings: [LayerAudioBinding] = [],
         keyframes: [CompositionKeyframe] = []) {
        self.id = id
        self.kind = kind
        self.zIndex = zIndex
        self.activeRange = activeRange
        self.properties = properties
        self.bindings = bindings
        self.keyframes = keyframes
    }

    func isValid(in timeline: CompositionTimeline) -> Bool {
        guard !id.isEmpty, id.count <= 128, (-100...100).contains(zIndex),
              bindings.count <= 16, keyframes.count <= 256,
              properties.allSatisfy({ $0.key.accepts($0.value) }),
              Set(bindings.map(\.property)).count == bindings.count,
              keyframes.allSatisfy({ $0.isValid && $0.timestamp <= timeline.duration }),
              activeRange.map({ $0.isValid && $0.end <= timeline.duration }) ?? true else {
            return false
        }
        var positions: [LayerProperty: Set<Double>] = [:]
        for frame in keyframes {
            guard positions[frame.property, default: []]
                .insert(frame.timestamp).inserted else { return false }
        }
        return true
    }

    func isActive(at elapsed: TimeInterval) -> Bool {
        activeRange?.contains(elapsed) ?? true
    }

    /// Stable IDs/order for wrapping an existing preset; these do NOT enable rendering.
    static let defaultLayers: [PresetLayer] = [
        PresetLayer(id: "background", kind: .background, zIndex: 0),
        PresetLayer(id: "artwork", kind: .artwork, zIndex: 10),
        PresetLayer(id: "typography", kind: .typography, zIndex: 20),
        PresetLayer(id: "overlay", kind: .overlay, zIndex: 30)
    ]
}
