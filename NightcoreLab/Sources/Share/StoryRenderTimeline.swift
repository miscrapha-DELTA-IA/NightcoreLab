import Foundation

/// Offline equivalent of the live kick release, sampled solely in source time.
/// A binary search keeps scrubbing and out-of-order frame requests identical.
enum StoryBeatEnvelope {
    static func at(sourceTime: TimeInterval, dna: SongDNA?) -> Double {
        guard sourceTime.isFinite, let beats = dna?.beatTimestamps,
              !beats.isEmpty else { return 0 }
        var low = 0, high = beats.count
        while low < high {
            let middle = (low + high) / 2
            if beats[middle] <= sourceTime { low = middle + 1 }
            else { high = middle }
        }
        guard low > 0 else { return 0 }
        let elapsed = sourceTime - beats[low - 1]
        return elapsed < 1 ? exp(-elapsed / 0.24) : 0
    }
}

/// A SwiftRender-inspired, deterministic scene clock. Rendering is a pure
/// function of the immutable StoryVideoRequest and integer presentation frame.
/// The same frame is used by the preview, still captures and MP4 encoder.
struct StoryRenderFrame: Equatable, Sendable {
    let index: Int
    let elapsed: TimeInterval
    let sourceTime: TimeInterval
    let lyricTime: TimeInterval
    let marblePhase: Float
    /// Source-time matched pad visual accent for THIS exact presentation frame.
    var padAccent: PadVisualAccent? = nil
}

/// Media time uses the original source clock (already includes playback speed).
/// The frame grid is frozen with the export profile at the moment the draft
/// is opened; Low Power Mode cannot change it halfway through a render.
struct StoryRenderTimeline: Sendable {
    let request: StoryVideoRequest
    let profile: StoryEncodingProfile

    var frameCount: Int { profile.frameCount(duration: request.duration) }
    var lastFrameIndex: Int { frameCount - 1 }
    var lastFrameElapsed: TimeInterval {
        Double(lastFrameIndex) / Double(profile.fps)
    }

    func frame(index: Int) -> StoryRenderFrame {
        let clamped = min(max(index, 0), lastFrameIndex)
        let seconds = Double(clamped) / Double(profile.fps)
        return StoryRenderFrame(index: clamped, elapsed: seconds,
                                sourceTime: request.sourceTime(at: seconds),
                                lyricTime: request.lyricTime(at: seconds),
                                marblePhase: request.marbleTime(at: seconds),
                                padAccent: PadVisualAccentResolver.at(
                                    sourceTime: request.sourceTime(at: seconds),
                                    timeline: request.padPerformance))
    }

    /// Preview scrubbing snaps to the exact same frame grid as the encoder.
    func frame(at elapsed: TimeInterval) -> StoryRenderFrame {
        guard elapsed.isFinite else { return frame(index: 0) }
        let bounded = min(max(elapsed, 0), lastFrameElapsed)
        return frame(index: Int((bounded * Double(profile.fps)).rounded()))
    }
}


/// Continuous export modulation. Geometry is always the authored, frozen base;
/// audio only drives a gentle bloom and never time-warps folds or UVs.
enum StoryExportMotion {
    static func phase(at renderTimestamp: TimeInterval, start: Float, speed: Float) -> Float {
        start + Float(max(0, renderTimestamp)) * speed
    }

    static func smoothBeat(at time: TimeInterval, dna: SongDNA?) -> Double {
        guard time.isFinite, let beats = dna?.beatTimestamps else { return 0 }
        // O(log N), not O(total song beats) for every off-screen MP4 frame.
        // Keep the Gaussian untruncated to avoid boundary jumps.
        guard !beats.isEmpty else { return 0 }
        var low = 0, high = beats.count
        while low < high {
            let mid = (low + high) / 2
            if beats[mid] < time { low = mid + 1 } else { high = mid }
        }
        let lower = max(0, low - 2), upper = min(beats.count, low + 2)
        var peak = 0.0
        for index in lower..<upper {
            let normalized = abs(time - beats[index]) / 0.18
            peak = max(peak, exp(-0.5 * normalized * normalized))
        }
        return min(1, peak)
    }

    static func material(base: MaterialFrame, mode: CreativePreset.AudioReaction,
                         sourceTime: TimeInterval, dna: SongDNA?) -> MaterialFrame {
        let p = base.parameters
        let pulse = mode == .responsive ? 0.18 * smoothBeat(at: sourceTime, dna: dna) : 0
        let breath = mode == .off ? 0 :
            (0.5 + 0.5 * sin(sourceTime * 2 * .pi / 3.6)) * (mode == .subtle ? 0.045 : 0.018)
        let brightness = min(0.3, p.brightnessBoost + breath + pulse * 0.24)
        let params = VisualParameterSet(
            distortion: p.distortion, beatPulse: pulse,
            pulseDecay: p.pulseDecay, offbeatScale: p.offbeatScale,
            warpAmount: p.warpAmount, brightnessBoost: brightness,
            stripingFrequency: p.stripingFrequency, stripingMix: p.stripingMix,
            speckleIntensity: p.speckleIntensity, embossStrength: p.embossStrength,
            scanlineDensity: p.scanlineDensity, diffusionSoftness: p.diffusionSoftness,
            voidThreshold: p.voidThreshold, combStretch: p.combStretch,
            bilateralSymmetry: p.bilateralSymmetry, halftoneGrating: p.halftoneGrating)
        let energy = mode == .off ? 0 : min(1, pulse + breath)
        return MaterialFrame(materialID: base.materialID, type: base.type,
            parameters: params, intensity: base.intensity,
            audioResponse: MaterialAudioResponse(distortion: 0, brightness: energy,
                pulse: pulse, accent: 0), timestamp: base.timestamp,
            seed: base.seed, controls: base.controls,
            signals: MaterialReactiveSignals(energy: energy, bass: 0,
                movement: 0, brightness: energy), viewport: base.viewport)
    }
}
