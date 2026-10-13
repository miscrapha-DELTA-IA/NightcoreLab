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
        let velocity: Float
        let voice: Int
    }

    /// Render timestamps are media-source seconds mapped through the frozen
    /// export rate, not a second independent karaoke or player clock.
    static func schedule(_ timeline: PerformanceTimeline, kit: PadKit,
                         startTime: TimeInterval, speed: Float,
                         sampleRate: Double, polyphony: Int = 12) throws -> [ScheduledHit] {
        guard timeline.isValid, timeline.kitID == kit.id, kit.isValid,
              startTime.isFinite, startTime >= 0,
              speed.isFinite, speed > 0, sampleRate > 0 else {
            throw AudioEngineError.unsupportedAudio
        }
        let byID = Dictionary(uniqueKeysWithValues: kit.samples.map { ($0.id, $0) })
        let ordered = timeline.events.compactMap { event -> (PadEvent, SampleDescriptor, Int64)? in
            guard let sample = byID[event.padId] else { return nil }
            let elapsed = event.sourceTime.map {
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
            for voice in selection.chokeIndices + [selection.voiceIndex] {
                if let previous = latestByVoice[voice] {
                    hits[previous].endFrame = min(hits[previous].endFrame, startFrame)
                }
            }
            latestByVoice[selection.voiceIndex] = hits.count
            for voice in selection.chokeIndices {
                latestByVoice[voice] = nil
            }
            hits.append(ScheduledHit(
                sample: sample, startFrame: startFrame,
                endFrame: startFrame + Int64((sample.duration * sampleRate).rounded()),
                velocity: event.velocity, voice: selection.voiceIndex))
        }
        return hits
    }

    static func write(_ timeline: PerformanceTimeline, kit: PadKit = .starter,
                      startTime: TimeInterval, speed: Float,
                      duration: TimeInterval, sampleRate: Double) throws -> URL {
        guard duration.isFinite, duration > 0, duration <= 3600,
              sampleRate.isFinite, sampleRate > 0 else {
            throw AudioEngineError.unsupportedAudio
        }
        let hits = try schedule(timeline, kit: kit, startTime: startTime,
                                speed: speed, sampleRate: sampleRate)
        let sourceBuffers = Dictionary(uniqueKeysWithValues: kit.samples.compactMap { sample in
            PadSampleSynthesizer.make(sample).map { (sample.id, $0) }
        })
        guard sourceBuffers.count == kit.samples.count else {
            throw AudioEngineError.bufferAllocationFailed
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
                                  hit.endFrame > frame {
                guard let source = sourceBuffers[hit.sample.id],
                      let channel = source.floatChannelData?[0] else { continue }
                let lower = max(frame, hit.startFrame)
                let upper = min(frame + Int64(length), hit.endFrame)
                let ratio = PadSampleSynthesizer.sampleRate / sampleRate
                let gain = hit.sample.gain * hit.velocity
                for time in lower..<upper {
                    let input = Double(time - hit.startFrame) * ratio
                    let index = Int(input)
                    guard index >= 0, index < Int(source.frameLength) else { continue }
                    let weight = Float(input - Double(index))
                    let v0 = channel[index]
                    let v1 = channel[min(index + 1, Int(source.frameLength) - 1)]
                    let value = gain * (v0 + (v1 - v0) * weight)
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
