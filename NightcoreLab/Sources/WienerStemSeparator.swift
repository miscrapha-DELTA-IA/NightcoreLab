import Accelerate
import AVFoundation
import Foundation

/// Development-only offline spectral separator. Unlike the previous per-sample
/// EQ proxy, this creates four independently mixed and phase-aligned tracks.
/// Wiener-style spectral masks are approximate: a Demucs model is still needed
/// for studio-grade source isolation. No work runs on the audio callback.
enum WienerStemSeparator {
    static let windowSize = 2048
    static let hopSize = 512
    static let overlap = 0.75

    static func separate(source: URL, urls: [StemKind: URL]) throws {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32,
                                    interleaved: false)
        let format = input.processingFormat
        guard format.sampleRate > 0, (1...2).contains(format.channelCount),
              input.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let stereo = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2)!
        let compressedSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 96_000
        ]
        let writers = try Dictionary(uniqueKeysWithValues: StemKind.allCases.map { kind in
            (kind, try AVAudioFile(forWriting: urls[kind]!, settings: compressedSettings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false))
        })
        let n = windowSize, hop = hopSize
        guard let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD),
              let inverse = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .INVERSE),
              let readBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(hop))
        else { throw CocoaError(.fileReadUnknown) }
        defer { vDSP_DFT_DestroySetup(forward); vDSP_DFT_DestroySetup(inverse) }

        let window = (0..<n).map { index -> Float in
            0.5 - 0.5 * cos(2 * Float.pi * Float(index) / Float(n - 1))
        }
        var incoming = [[Float]](repeating: [Float](repeating: 0, count: n), count: 2)
        var overlapOutput = [[[Float]]](
            repeating: [Float](repeating: 0, count: n).duplicated(count: 2), count: 4)
        var overlapWeight = [Float](repeating: 0, count: n)
        var previous = [Float](repeating: 0, count: n)

        let kinds = StemKind.allCases
        let rate = Float(format.sampleRate)
        var readFrames = 0
        var produced = 0
        let countFrames = Int(input.length)

        func readSamples(_ length: Int, into offset: Int) throws -> Int {
            try input.read(into: readBuffer, frameCount: AVAudioFrameCount(length))
            let lengthRead = Int(readBuffer.frameLength)
            let channels = readBuffer.floatChannelData
            for ch in 0..<2 {
                let sourceChannel = format.channelCount == 1 ? 0 : ch
                for sample in 0..<lengthRead {
                    incoming[ch][offset + sample] = channels![sourceChannel][sample]
                }
                if lengthRead < length {
                    for sample in lengthRead..<length {
                        incoming[ch][offset + sample] = 0
                    }
                }
            }
            return lengthRead
        }

        readFrames += try readSamples(n, into: 0)
        while produced < countFrames {
            try Task.checkCancellation()
            var spectraR = [[Float]](repeating: [Float](repeating: 0, count: n), count: 2)
            var spectraI = spectraR
            for ch in 0..<2 {
                var signal = [Float](repeating: 0, count: n)
                var zeros = signal
                for i in 0..<n { signal[i] = incoming[ch][i] * window[i] }
                vDSP_DFT_Execute(forward, &signal, &zeros, &spectraR[ch], &spectraI[ch])
            }
            var masks = [[Float]](repeating: [Float](repeating: 0, count: n), count: 4)
            for bin in 0..<n {
                let folded = min(bin, n - bin)
                let hz = Float(folded) * rate / Float(n)
                let midR = (spectraR[0][bin] + spectraR[1][bin]) * 0.5
                let midI = (spectraI[0][bin] + spectraI[1][bin]) * 0.5
                let sideR = (spectraR[0][bin] - spectraR[1][bin]) * 0.5
                let sideI = (spectraI[0][bin] - spectraI[1][bin]) * 0.5
                let centered = hypot(midR, midI)
                let side = hypot(sideR, sideI)
                let transient = max(0, centered - previous[bin]) /
                                max(0.00001, centered)
                previous[bin] = 0.85 * previous[bin] + 0.15 * centered
                // Independent time-frequency masks; low frequencies favour
                // bass, center mid-range harmonic bins favour voice, spectral
                // transients favour drums, and residual energy favours other.
                let bass = 0.08 + 3.2 / (1 + pow(max(1, hz) / 165, 6))
                let vocalBand = hz > 200 && hz < 3800 ? Float(1) : Float(0.08)
                let centerRatio = centered / max(0.00001, centered + side)
                let voice = 0.08 + 2.5 * vocalBand * centerRatio * (1 - transient)
                let drums = 0.08 + 2.5 * transient * (hz > 80 ? Float(1) : Float(0.12))
                let other = 0.22 + 0.8 * side / max(0.00001, centered + side)
                let powers = [voice * voice, other * other, drums * drums, bass * bass]
                let total = powers.reduce(0, +)
                for stem in 0..<4 { masks[stem][bin] = powers[stem] / total }
            }
            // Hann synthesis with 75% overlap yields matched 512-frame
            // interleaved stem windows and a common hardware-clock start.
            for stem in 0..<4 {
                for ch in 0..<2 {
                    var real = [Float](repeating: 0, count: n)
                    var imag = real
                    var resultR = real
                    var resultI = real
                    for i in 0..<n {
                        real[i] = spectraR[ch][i] * masks[stem][i]
                        imag[i] = spectraI[ch][i] * masks[stem][i]
                    }
                    vDSP_DFT_Execute(inverse, &real, &imag, &resultR, &resultI)
                    for i in 0..<n {
                        overlapOutput[stem][ch][i] += resultR[i] * window[i] / Float(n)
                    }
                }
            }
            for i in 0..<n { overlapWeight[i] += window[i] * window[i] }
            let emit = min(hop, countFrames - produced)
            outBuffer.frameLength = AVAudioFrameCount(emit)
            for (index, kind) in kinds.enumerated() {
                guard let dest = outBuffer.floatChannelData else { throw CocoaError(.fileWriteUnknown) }
                for channel in 0..<2 {
                    for i in 0..<emit {
                        dest[channel][i] = overlapOutput[index][channel][i] /
                            max(overlapWeight[i], 0.000001)
                    }
                }
                try writers[kind]!.write(from: outBuffer)
            }
            produced += emit
            for ch in 0..<2 {
                incoming[ch].removeFirst(hop)
                incoming[ch].append(contentsOf: repeatElement(Float(0), count: hop))
            }
            if readFrames < countFrames {
                readFrames += try readSamples(min(hop, countFrames - readFrames), into: n - hop)
            }
            for stem in 0..<4 {
                for channel in 0..<2 {
                    overlapOutput[stem][channel].removeFirst(hop)
                    overlapOutput[stem][channel].append(contentsOf: repeatElement(Float(0), count: hop))
                }
            }
            overlapWeight.removeFirst(hop)
            overlapWeight.append(contentsOf: repeatElement(Float(0), count: hop))
        }
    }
}

private extension Array where Element == Float {
    func duplicated(count: Int) -> [[Float]] {
        (0..<count).map { _ in self }
    }
}
