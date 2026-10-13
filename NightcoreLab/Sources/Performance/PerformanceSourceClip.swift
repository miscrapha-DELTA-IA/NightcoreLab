import AVFoundation
import Foundation

/// One bounded, non-persistent source-range assignment. Never contains the
/// source URL or a downloaded/copied audio asset.
struct PerformanceSourceClip: Codable, Equatable, Sendable {
    static let slotID = "source-clip"
    static let maxLength: TimeInterval = 5
    static let minLength: TimeInterval = 0.25
    let startTime: TimeInterval
    let endTime: TimeInterval

    var duration: TimeInterval { endTime - startTime }
    var isValid: Bool {
        startTime.isFinite && startTime >= 0 &&
        endTime.isFinite && duration >= Self.minLength &&
        duration <= Self.maxLength
    }

    init?(startTime: TimeInterval, duration: TimeInterval,
          sourceDuration: TimeInterval) {
        guard startTime.isFinite && duration.isFinite &&
              sourceDuration.isFinite && sourceDuration > 0,
              startTime >= 0 && startTime < sourceDuration,
              duration >= Self.minLength && duration <= Self.maxLength,
              startTime + duration <= sourceDuration + 0.000_001 else { return nil }
        self.startTime = startTime
        endTime = min(startTime + duration, sourceDuration)
        guard isValid else { return nil }
    }

    var descriptor: SampleDescriptor {
        SampleDescriptor(id: Self.slotID, name: "CLIP",
                         category: .sample, asset: "nightcore.source-clip.v1",
                         license: "Local selection: user must hold sharing rights",
                         duration: duration, gain: 0.75, defaultVelocity: 0.85,
                         loop: false, chokeGroup: nil)
    }
}

/// Portable audio data sent back to the main actor after one background decode.
/// Maximum PCM memory at 48k, stereo, five seconds: ~1.92 MB.
struct PerformanceClipPCM: Sendable {
    let left: [Float]
    let right: [Float]

    func makeBuffer() -> AVAudioPCMBuffer? {
        guard left.count == right.count, !left.isEmpty,
              left.count <= Int(PerformanceSourceClip.maxLength * 48_000) else { return nil }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(left.count)),
              let a = buffer.floatChannelData?[0],
              let b = buffer.floatChannelData?[1] else { return nil }
        buffer.frameLength = AVAudioFrameCount(left.count)
        left.withUnsafeBufferPointer { source in
            if let start = source.baseAddress { a.update(from: start, count: left.count) }
        }
        right.withUnsafeBufferPointer { source in
            if let start = source.baseAddress { b.update(from: start, count: right.count) }
        }
        return buffer
    }
}

/// Decodes a selected range only, never the whole source into memory.
/// Uses bounded linear resampling for the initial MVP; assess higher quality
/// AVAudioConverter resampling on device before adding a higher-fidelity mode.
enum PerformanceClipExtractor {
    enum Error: Swift.Error { case invalidSource, decodeFailure }

    static func decode(from source: URL, clip: PerformanceSourceClip) throws -> PerformanceClipPCM {
        guard clip.isValid, source.isFileURL else { throw Error.invalidSource }
        let file = try AVAudioFile(forReading: source,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let rate = format.sampleRate
        let channels = Int(format.channelCount)
        guard rate.isFinite, rate > 0, (1...2).contains(channels) else {
            throw Error.invalidSource
        }
        let start = Int64((clip.startTime * rate).rounded(.down))
        let readFrames = Int((clip.duration * rate).rounded(.up)) + 2
        guard start >= 0, start < file.length,
              readFrames > 0, readFrames < 1_000_000 else { throw Error.invalidSource }
        file.framePosition = start
        guard let input = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(readFrames)) else {
            throw Error.decodeFailure
        }
        try file.read(into: input, frameCount: AVAudioFrameCount(
            min(Int64(readFrames), file.length - start)))
        guard input.frameLength > 0,
              let first = input.floatChannelData?[0] else { throw Error.decodeFailure }
        let second = channels == 2 ? input.floatChannelData?[1] : nil
        let outputFrames = Int((clip.duration * 48_000).rounded(.down))
        guard outputFrames > 0, outputFrames <= Int(5 * 48_000) else {
            throw Error.invalidSource
        }
        var left = [Float](repeating: 0, count: outputFrames)
        var right = [Float](repeating: 0, count: outputFrames)
        let limit = Int(input.frameLength) - 1
        for i in 0..<outputFrames {
            let index = Double(i) * rate / 48_000
            let low = min(Int(index), limit)
            let high = min(low + 1, limit)
            let alpha = Float(index - Double(low))
            let fade = Float(min(1, min(Double(i) / 240,
                                           Double(outputFrames - 1 - i) / 480)))
            let a = (first[low] + (first[high] - first[low]) * alpha) * fade
            let other = second ?? first
            let c = (other[low] + (other[high] - other[low]) * alpha) * fade
            left[i] = a.isFinite ? a : 0
            right[i] = c.isFinite ? c : 0
        }
        return PerformanceClipPCM(left: left, right: right)
    }
}
