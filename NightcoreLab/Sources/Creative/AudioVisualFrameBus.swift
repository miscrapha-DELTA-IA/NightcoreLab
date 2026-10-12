import Foundation

/// Fosfora-inspired consumer seam. In the future a live analyzer can enqueue
/// features without updating SwiftUI or coupling to AVAudioEngine.
///
/// Continuous values are "latest wins" (drop oldest on overflow). Events
/// survive dropped frames via a monotonic event counter. NOT a real-time
/// audio callback interface: no allocations are allowed in such callbacks.
actor AudioVisualFrameBus {
    struct Packet: Equatable, Sendable {
        let sourceTime: TimeInterval
        let features: AudioFeatures
        /// Total onset events published since the last reset.
        let beatSequence: UInt64
    }

    private var queue: [Packet] = []
    private var beatSequence: UInt64 = 0
    private var lastTimestamp: TimeInterval?
    private(set) var droppedFrames = 0

    let capacity: Int

    init(capacity: Int = 4) {
        self.capacity = max(1, capacity)
    }

    /// Discard stale values after a seek / restart before publishing again.
    func publish(_ point: AudioFeaturePoint) {
        guard point.time.isFinite, point.time >= 0 else { return }
        if let previous = lastTimestamp {
            if point.time < previous { reset() }
            else if point.time == previous { return } // no duplicate onset
        }
        lastTimestamp = point.time
        if point.features.beatDetected { beatSequence &+= 1 }
        queue.append(Packet(sourceTime: point.time, features: point.features,
                            beatSequence: beatSequence))
        if queue.count > capacity {
            queue.removeFirst(queue.count - capacity)
            droppedFrames += 1
        }
    }

    /// Drains to newest. A slow consumer needn't render old frames, and can
    /// calculate beat pulses via newSequence - its previously seen sequence.
    func drainLatest() -> Packet? {
        let latest = queue.last
        queue.removeAll(keepingCapacity: true)
        return latest
    }

    func reset() {
        queue.removeAll(keepingCapacity: true)
        beatSequence = 0
        lastTimestamp = nil
        droppedFrames = 0
    }
}

/// Versioned, typed binding targets; avoids strings that accidentally point
/// to the wrong visual control and does not allow arbitrary executable shaders.
enum CreativeVisualTarget: String, CaseIterable, Codable, Sendable {
    case playerGlow
    case marbleDistortion
    case lyricKinetics
    case particleEmission
}

struct CreativeVisualBindings: Equatable, Codable, Sendable {
    /// No dynamic graph or reflection: typed, bounded values only.
    func value(for target: CreativeVisualTarget,
               response: VisualResponse) -> Double {
        switch target {
        case .playerGlow: return unit(response.glow)
        case .marbleDistortion: return unit(response.distortionAmount)
        case .lyricKinetics: return unit(response.wordAnimationIntensity)
        case .particleEmission: return unit(response.emissionRate)
        }
    }

    private func unit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}
