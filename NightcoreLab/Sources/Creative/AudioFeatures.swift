import Foundation

/// Normalized, immutable visual descriptors (0...1), not live AVAudioEngine state.
/// Silent by default; Block 2 can optionally populate it from a local file.
struct AudioFeatures: Codable, Equatable, Sendable {
    let bass: Double
    let mid: Double
    let treble: Double
    let energy: Double
    let beatDetected: Bool

    static let silent = AudioFeatures()

    /// Compatibility aliases for future audio-reactive integrations.
    /// They derive from existing stored values, avoiding duplicate state.
    var amplitude: Double { energy }
    var mids: Double { mid }

    init(bass: Double = 0, mid: Double = 0, treble: Double = 0,
         energy: Double = 0, beatDetected: Bool = false) {
        self.bass = Self.normalized(bass)
        self.mid = Self.normalized(mid)
        self.treble = Self.normalized(treble)
        self.energy = Self.normalized(energy)
        self.beatDetected = beatDetected
    }

    private static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private enum CodingKeys: String, CodingKey {
        case bass, mid, treble, energy, beatDetected
    }

    /// Validate external/older payloads too; synthesized decoding would bypass init.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bass: try values.decode(Double.self, forKey: .bass),
            mid: try values.decode(Double.self, forKey: .mid),
            treble: try values.decode(Double.self, forKey: .treble),
            energy: try values.decode(Double.self, forKey: .energy),
            beatDetected: try values.decode(Bool.self, forKey: .beatDetected)
        )
    }
}

/// Optional future input supplied by an audio analyzer, in normalized units.
/// A frame is supplied explicitly; no tap or audio analysis starts automatically.
struct AudioFeatureFrame: Sendable {
    let bassLevel: Double
    let midLevel: Double
    let trebleLevel: Double
    let rmsLevel: Double
    let beatDetected: Bool

    init(bassLevel: Double, midLevel: Double, trebleLevel: Double,
         rmsLevel: Double, beatDetected: Bool = false) {
        self.bassLevel = bassLevel
        self.midLevel = midLevel
        self.trebleLevel = trebleLevel
        self.rmsLevel = rmsLevel
        self.beatDetected = beatDetected
    }
}
