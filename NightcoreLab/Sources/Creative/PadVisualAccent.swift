import Foundation

/// Pad accents are semantic impulses: colors are selected by the active
/// Material palette, rather than introducing theme-specific RGB fallbacks.
enum PadAccentBand: String, Codable, Equatable, Sendable {
    case low, mid, high
    static func forPad(_ padID: String) -> Self {
        switch padID {
        case "kick", "808": return .low
        case "snare", "clap": return .mid
        default: return .high
        }
    }
}

struct PadVisualImpulse: Codable, Equatable, Sendable {
    let padID: String
    let velocity: Float
    let band: PadAccentBand
    let time: TimeInterval

    init(padID: String, velocity: Float, time: TimeInterval) {
        self.padID = padID
        self.velocity = velocity.isFinite ? min(1, max(0, velocity)) : 0
        self.band = .forPad(padID)
        self.time = time
    }
}

struct PadVisualAccent: Equatable, Sendable {
    let band: PadAccentBand
    let strength: Double
}

/// Pure, history-free evaluator shared by a LIVE impulse and the frozen Story
/// timeline. A change of FPS or frame traversal order cannot alter the result.
enum PadVisualAccentResolver {
    static let visibleWindow: TimeInterval = 0.75
    static func envelope(_ impulse: PadVisualImpulse, at time: TimeInterval)
        -> PadVisualAccent? {
        let delta = time - impulse.time
        guard time.isFinite, impulse.time.isFinite, delta >= 0,
              delta < visibleWindow else { return nil }
        let decay = exp(-delta * 8.0)
        let strength = min(1, max(0, Double(impulse.velocity) * decay))
        guard strength > 0.002 else { return nil }
        return PadVisualAccent(band: impulse.band, strength: strength)
    }

    static func at(sourceTime: TimeInterval, timeline: PerformanceTimeline?)
        -> PadVisualAccent? {
        guard let timeline, timeline.isValid, sourceTime.isFinite else { return nil }
        var maximum: PadVisualAccent?
        for hit in timeline.events {
            guard let time = CompositionRuntime.padEventSourceTime(
                hit, quantizeStrength: timeline.quantizeStrength) else { continue }
            let impulse = PadVisualImpulse(padID: hit.padId, velocity: hit.velocity, time: time)
            if let candidate = envelope(impulse, at: sourceTime),
               candidate.strength > (maximum?.strength ?? 0) {
                maximum = candidate
            }
        }
        return maximum
    }

    static func apply(_ frame: MaterialFrame, accent: PadVisualAccent?) -> MaterialFrame {
        guard let accent, accent.strength > 0 else { return frame }
        let p = frame.parameters
        let low = accent.band == .low ? 1.0 : 0.30
        let high = accent.band == .high ? 1.0 : 0.55
        let strength = accent.strength
        let updated = VisualParameterSet(
            distortion: p.distortion + strength * 0.17 * low,
            beatPulse: max(p.beatPulse, strength * 0.75),
            pulseDecay: p.pulseDecay, offbeatScale: p.offbeatScale,
            warpAmount: p.warpAmount + strength * 0.07 * low,
            brightnessBoost: p.brightnessBoost + strength * 0.12 * high,
            stripingFrequency: p.stripingFrequency, stripingMix: p.stripingMix,
            speckleIntensity: p.speckleIntensity, embossStrength: p.embossStrength,
            scanlineDensity: p.scanlineDensity,
            diffusionSoftness: p.diffusionSoftness,
            voidThreshold: p.voidThreshold, combStretch: p.combStretch,
            bilateralSymmetry: p.bilateralSymmetry,
            halftoneGrating: p.halftoneGrating)
        return MaterialFrame(materialID: frame.materialID, type: frame.type,
                             parameters: updated, intensity: frame.intensity,
                             audioResponse: frame.audioResponse, timestamp: frame.timestamp,
                             seed: frame.seed, controls: frame.controls,
                             signals: frame.signals, viewport: frame.viewport)
    }
}

/// Only one emitter for the one AudioEngineManager. No SwiftUI/Observable
/// notifications on pad hits; the displayed TimelineView pulls once per frame.
@MainActor
final class PadVisualAccentEmitter {
    private var impulses: [PadVisualImpulse] = []
    func trigger(_ padID: String, velocity: Float,
                 at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard uptime.isFinite, uptime >= 0 else { return }
        impulses.removeAll { uptime - $0.time > PadVisualAccentResolver.visibleWindow }
        impulses.append(PadVisualImpulse(padID: padID, velocity: velocity, time: uptime))
        if impulses.count > 16 { impulses.removeFirst(impulses.count - 16) }
    }

    func accent(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime)
        -> PadVisualAccent? {
        var maximum: PadVisualAccent?
        for impulse in impulses {
            if let candidate = PadVisualAccentResolver.envelope(impulse, at: uptime),
               candidate.strength > (maximum?.strength ?? 0) {
                maximum = candidate
            }
        }
        return maximum
    }
    func clear() { impulses.removeAll(keepingCapacity: true) }
}
