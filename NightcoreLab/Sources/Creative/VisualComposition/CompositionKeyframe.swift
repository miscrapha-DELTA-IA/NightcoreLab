import Foundation

/// All layer parameters have explicit units/ranges. No free-form key paths.
enum LayerProperty: String, Codable, CaseIterable, Sendable {
    case opacity, scale, offsetX, offsetY, rotation, intensity

    var defaultValue: Double {
        switch self {
        case .opacity, .scale, .intensity: return 1
        case .offsetX, .offsetY, .rotation: return 0
        }
    }

    var bounds: ClosedRange<Double> {
        switch self {
        case .opacity, .intensity: return 0...1
        case .scale: return 0...4
        case .offsetX, .offsetY: return -1...1  // fraction of canvas dimensions
        case .rotation: return -Double.pi...Double.pi // radians
        }
    }

    func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return Swift.min(bounds.upperBound, Swift.max(bounds.lowerBound, value))
    }

    func accepts(_ value: Double) -> Bool {
        value.isFinite && bounds.contains(value)
    }
}

enum CompositionEasing: String, Codable, Sendable {
    case hold, linear, easeInOut

    /// A keyframe's easing is applied to the segment ARRIVING at this keyframe.
    func progress(_ x: Double) -> Double {
        let t = Swift.min(1, Swift.max(0, x))
        switch self {
        case .hold: return 0
        case .linear: return t
        case .easeInOut: return t * t * (3 - 2 * t)
        }
    }
}

struct CompositionKeyframe: Codable, Equatable, Sendable {
    let timestamp: TimeInterval   // video elapsed seconds; never source audio time
    let property: LayerProperty
    let value: Double
    let easing: CompositionEasing

    init(timestamp: TimeInterval, property: LayerProperty, value: Double,
         easing: CompositionEasing = .linear) {
        self.timestamp = timestamp
        self.property = property
        self.value = value
        self.easing = easing
    }

    var isValid: Bool {
        timestamp.isFinite && timestamp >= 0 && property.accepts(value)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(timestamp: try c.decode(Double.self, forKey: .timestamp),
                  property: try c.decode(LayerProperty.self, forKey: .property),
                  value: try c.decode(Double.self, forKey: .value),
                  easing: try c.decode(CompositionEasing.self, forKey: .easing))
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Invalid keyframe"))
        }
    }
}
