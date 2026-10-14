import AVFoundation
import Foundation

/// Deterministic, bounded-memory offline pad stem used by the *existing*
/// AudioEngineManager.renderOffline graph. This does not create an AVAudioEngine.
/// It builds a temporary WAV only when explicitly exporting a performance;
/// no file IO ever happens on a touch or inside the live audio graph.
enum PerformancePadMixdown {
    struct ScheduledHit {
        let sample: SampleDescriptor
        let startFrame: Int64
        var endFrame: Int64
        /// Bounded outgoing voice release; preserves the original cut instant.
        var releaseFrames: Int64
        let velocity: Float
        let voice: Int
    }

    /// Render timestamps are media-source seconds mapped through the frozen
    /// export rate, not a second independent karaoke or player clock.
    static func schedule(_ timeline: PerformanceTimeline, kit: PadKit,
                         startTime: TimeInterval, speed: Float,
                         sampleRate: Double, polyphony: Int = 12) throws -> [ScheduledHit] {
        let effectiveKit = timeline.sourceClip.map {
            PadKit(id: kit.id, name: kit.name,
                   samples: kit.samples + [$0.descriptor])
        } ?? kit
        guard timeline.isValid, timeline.kitID == kit.id, effectiveKit.isValid,
              startTime.isFinite, startTime >= 0,
              speed.isFinite, speed > 0, sampleRate > 0 else {
            throw AudioEngineError.unsupportedAudio
        }
        let byID = Dictionary(uniqueKeysWithValues: effectiveKit.samples.map { ($0.id, $0) })
        let ordered = timeline.events.compactMap { event -> (PadEvent, SampleDescriptor, Int64)? in
            guard let sample = byID[event.padId] else { return nil }
            // Both offline export and CompositionRuntime preview share the
            // same optional groove transform. Raw timestamps remain intact.
            let elapsed = CompositionRuntime.padEventSourceTime(
                event, quantizeStrength: timeline.quantizeStrength).map {
                    ($0 - startTime) / Double(speed)
                } ?? event.timestamp
            guard elapsed.isFinite, elapsed > -5,
                  elapsed < Double(Int64.max / 4) / sampleRate else { return nil }
            return (event, sample, Int64((elapsed * sampleRate).rounded()))
        }.sorted {
            $0.2 == $1.2 ? $0.0.id.uuidString < $1.0.id.uuidString :
                $0.2 < $1.2
        }
        var allocator = PadVoiceAllocator(capacity: polyphony)
        var hits: [ScheduledHit] = []
        var latestByVoice: [Int: Int] = [:]

        for (event, sample, startFrame) in ordered {
            let startSeconds = Double(startFrame) / sampleRate
            guard let selection = allocator.allocate(
                id: sample.id, chokeGroup: sample.chokeGroup,
                duration: sample.duration, at: startSeconds) else { continue }
            for interrupted in selection.interrupted {
                if let previous = latestByVoice[interrupted.voiceIndex] {
                    let cutFrame = min(hits[previous].endFrame, startFrame)
                    // Mirror the 8ms outgoing release lane of PadAudioRuntime,
                    // even though the offline mix can overlap without nodes.
                    let originalEnd = hits[previous].startFrame +
                        Int64((hits[previous].sample.duration * sampleRate).rounded())
                    let releaseLength = Int64((PadAudioRuntime.releaseSeconds * sampleRate).rounded())
                    hits[previous].endFrame = cutFrame
                    hits[previous].releaseFrames = max(0,
                        min(releaseLength, originalEnd - cutFrame))
                }
            }
            latestByVoice[selection.voiceIndex] = hits.count
            for voice in selection.chokeIndices {
                latestByVoice[voice] = nil
            }
            hits.append(ScheduledHit(
                sample: sample, startFrame: startFrame,
                endFrame: startFrame + Int64((sample.duration * sampleRate).rounded()),
                releaseFrames: 0,
                velocity: event.velocity, voice: selection.voiceIndex))
        }
        return hits
    }

    static func write(_ timeline: PerformanceTimeline, kit: PadKit = .starter,
                      startTime: TimeInterval, speed: Float,
                      duration: TimeInterval, sampleRate: Double,
                      sourceURL: URL? = nil) throws -> URL {
        guard duration.isFinite, duration > 0, duration <= 3600,
              sampleRate.isFinite, sampleRate > 0 else {
            throw AudioEngineError.unsupportedAudio
        }
        let hits = try schedule(timeline, kit: kit, startTime: startTime,
                                speed: speed, sampleRate: sampleRate)
        var sourceBuffers = Dictionary(uniqueKeysWithValues: kit.samples.compactMap { sample in
            PadSampleSynthesizer.make(sample).map { (sample.id, $0) }
        })
        guard sourceBuffers.count == kit.samples.count else {
            throw AudioEngineError.bufferAllocationFailed
        }
        if let clip = timeline.sourceClip {
            guard let sourceURL, sourceURL.isFileURL else {
                throw AudioEngineError.unsupportedAudio
            }
            let pcm = try PerformanceClipExtractor.decode(from: sourceURL, clip: clip)
            guard let buffer = pcm.makeBuffer() else {
                throw AudioEngineError.bufferAllocationFailed
            }
            sourceBuffers[PerformanceSourceClip.slotID] = buffer
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let totalFrames = Int64((duration * sampleRate).rounded(.up))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NightcorePerformance-\(UUID().uuidString).wav")
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: url) } }
        let output = try AVAudioFile(forWriting: url, settings: format.settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
              let left = buffer.floatChannelData?[0],
              let right = buffer.floatChannelData?[1] else {
            throw AudioEngineError.bufferAllocationFailed
        }

        var frame: Int64 = 0
        while frame < totalFrames {
            try Task.checkCancellation()
            let length = Int(min(4096, totalFrames - frame))
            for i in 0..<length { left[i] = 0; right[i] = 0 }
            for hit in hits where hit.startFrame < frame + Int64(length) &&
                                  hit.endFrame + hit.releaseFrames > frame {
                guard let source = sourceBuffers[hit.sample.id],
                      let channel = source.floatChannelData?[0] else { continue }
                let lower = max(frame, hit.startFrame)
                let upper = min(frame + Int64(length), hit.endFrame + hit.releaseFrames)
                let ratio = PadSampleSynthesizer.sampleRate / sampleRate
                let gain = hit.sample.gain * hit.velocity
                for time in lower..<upper {
                    let input = Double(time - hit.startFrame) * ratio
                    let index = Int(input)
                    guard index >= 0, index < Int(source.frameLength) else { continue }
                    let weight = Float(input - Double(index))
                    let v0 = channel[index]
                    let v1 = channel[min(index + 1, Int(source.frameLength) - 1)]
                    let releaseGain: Float
                    if hit.releaseFrames > 0 && time >= hit.endFrame {
                        let t = Float(time - hit.endFrame) / Float(hit.releaseFrames)
                        releaseGain = max(0, 1 - t) * max(0, 1 - t)
                    } else {
                        releaseGain = 1
                    }
                    let value = gain * releaseGain * (v0 + (v1 - v0) * weight)
                    let destination = Int(time - frame)
                    left[destination] += value
                    right[destination] += value
                }
            }
            buffer.frameLength = AVAudioFrameCount(length)
            try output.write(from: buffer)
            frame += Int64(length)
        }
        finished = true
        return url
    }
}
