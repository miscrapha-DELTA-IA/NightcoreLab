import Accelerate
import AVFoundation
import Foundation

/// Offline, two-stem experiment. It never touches the playback or microphone
/// graph: both outputs are aligned PCM files in the app's local cache.
enum NativeSpectralStemSeparator {
    static let windowSize = 2048
    static let hopSize = 512
    static let cacheVersion = "native-mid-side-v1"

    /// A zero mask below 140 Hz and above 5500 Hz keeps those bins entirely
    /// in the instrumental. The upper taper leaves the vocal formant range.
    static func vocalBandWeight(_ hertz: Float) -> Float {
        func smooth(_ value: Float) -> Float {
            let x = min(1, max(0, value))
            return x * x * (3 - 2 * x)
        }
        if hertz <= 140 || hertz >= 5500 { return 0 }
        if hertz < 250 { return smooth((hertz - 140) / 110) }
        if hertz <= 5000 { return 1 }
        return 1 - smooth((hertz - 5000) / 500)
    }

    /// Mid/side energy and interchannel phase agreement determine a bounded
    /// Wiener-style mask. Only the in-phase mid component is sent to vocals;
    /// subtracting it from each original channel retains the stereo sides.
    static func vocalMask(hertz: Float, leftReal: Float, leftImag: Float,
                          rightReal: Float, rightImag: Float) -> Float {
        let band = vocalBandWeight(hertz)
        if band == 0 { return 0 }
        let midReal = (leftReal + rightReal) * 0.5
        let midImag = (leftImag + rightImag) * 0.5
        let sideReal = (leftReal - rightReal) * 0.5
        let sideImag = (leftImag - rightImag) * 0.5
        let midPower = midReal * midReal + midImag * midImag
        let sidePower = sideReal * sideReal + sideImag * sideImag
        let epsilon: Float = 1e-12
        if midPower <= epsilon { return 0 }
        let leftPower = leftReal * leftReal + leftImag * leftImag
        let rightPower = rightReal * rightReal + rightImag * rightImag
        let phaseAgreement = max(0, min(1,
            (leftReal * rightReal + leftImag * rightImag) /
            max(epsilon, sqrt(leftPower * rightPower))))
        let centerConfidence = midPower / (midPower + 4 * sidePower + epsilon)
        let evidence = centerConfidence * phaseAgreement
        let voicePower = midPower * evidence * evidence
        let bedPower = 4 * sidePower + midPower * (1 - evidence) * (1 - evidence)
            + 0.05 * midPower
        return band * min(0.95, voicePower / (voicePower + bedPower + epsilon))
    }

    /// Calls progress with integer percentages from 0 through 100. The source
    /// is read in bounded chunks, and both destinations contain the same count
    /// of samples. No network or model file is used.
    static func separate(source: URL, instrumentalURL: URL, vocalsURL: URL,
                         progress: (Int) -> Void,
                         isCancelled: () -> Bool = { false }) throws {
        progress(0)
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32,
                                    interleaved: false)
        let inputFormat = input.processingFormat
        guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0,
              (1...2).contains(inputFormat.channelCount), input.length > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let rate = inputFormat.sampleRate
        guard let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let readBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                                frameCapacity: AVAudioFrameCount(windowSize)),
              let output = AVAudioPCMBuffer(pcmFormat: stereo,
                                            frameCapacity: AVAudioFrameCount(hopSize)),
              let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(windowSize), .FORWARD),
              let inverse = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(windowSize), .INVERSE)
        else { throw CocoaError(.fileReadUnknown) }
        defer { vDSP_DFT_DestroySetup(forward); vDSP_DFT_DestroySetup(inverse) }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true
        ]
        let instrumental = try AVAudioFile(forWriting: instrumentalURL, settings: settings,
                                            commonFormat: .pcmFormatFloat32, interleaved: false)
        let vocals = try AVAudioFile(forWriting: vocalsURL, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)

        let n = windowSize, hop = hopSize, padding = n / 2
        let frameCount = Int(input.length)
        let window = (0..<n).map { index in
            Float(0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(n)))
        }
        var incoming = Array(repeating: Array(repeating: Float(0), count: n), count: 2)
        var overlap = Array(repeating: Array(repeating: Array(repeating: Float(0), count: n), count: 2), count: 2)
        var weights = Array(repeating: Float(0), count: n)
        var readPosition = 0
        var frameStart = -padding
        var lastProgress = 0

        func readSamples(_ requested: Int, at offset: Int) throws {
            guard requested > 0 else { return }
            try input.read(into: readBuffer, frameCount: AVAudioFrameCount(requested))
            let count = Int(readBuffer.frameLength)
            guard let channels = readBuffer.floatChannelData else {
                throw CocoaError(.fileReadCorruptFile)
            }
            for channel in 0..<2 {
                let sourceChannel = inputFormat.channelCount == 1 ? 0 : channel
                for index in 0..<count {
                    incoming[channel][offset + index] = channels[sourceChannel][index]
                }
            }
            readPosition += count
        }

        try readSamples(min(padding, frameCount), at: padding)
        while frameStart < frameCount {
            if isCancelled() { throw CancellationError() }
            var real = Array(repeating: Array(repeating: Float(0), count: n), count: 2)
            var imaginary = real
            for channel in 0..<2 {
                var signal = Array(repeating: Float(0), count: n)
                var zeroes = signal
                for index in 0..<n { signal[index] = incoming[channel][index] * window[index] }
                vDSP_DFT_Execute(forward, &signal, &zeroes,
                                 &real[channel], &imaginary[channel])
            }

            var maskedReal = Array(repeating: Array(repeating: Array(repeating: Float(0), count: n), count: 2), count: 2)
            var maskedImaginary = maskedReal
            for bin in 0..<n {
                let hertz = Float(min(bin, n - bin)) * Float(rate) / Float(n)
                let mask = inputFormat.channelCount == 1 ? Float(0) : vocalMask(
                    hertz: hertz, leftReal: real[0][bin], leftImag: imaginary[0][bin],
                    rightReal: real[1][bin], rightImag: imaginary[1][bin])
                let vocalReal = (real[0][bin] + real[1][bin]) * 0.5 * mask
                let vocalImaginary = (imaginary[0][bin] + imaginary[1][bin]) * 0.5 * mask
                for channel in 0..<2 {
                    maskedReal[0][channel][bin] = real[channel][bin] - vocalReal
                    maskedImaginary[0][channel][bin] = imaginary[channel][bin] - vocalImaginary
                    maskedReal[1][channel][bin] = vocalReal
                    maskedImaginary[1][channel][bin] = vocalImaginary
                }
            }

            for stem in 0..<2 {
                for channel in 0..<2 {
                    var resultReal = Array(repeating: Float(0), count: n)
                    var resultImaginary = resultReal
                    vDSP_DFT_Execute(inverse, &maskedReal[stem][channel],
                                     &maskedImaginary[stem][channel],
                                     &resultReal, &resultImaginary)
                    for index in 0..<n {
                        overlap[stem][channel][index] += resultReal[index] * window[index] / Float(n)
                    }
                }
            }
            for index in 0..<n { weights[index] += window[index] * window[index] }

            let emitStart = max(0, frameStart)
            let emitEnd = min(frameCount, frameStart + hop)
            if emitEnd > emitStart {
                let count = emitEnd - emitStart
                let offset = emitStart - frameStart
                guard let destination = output.floatChannelData else {
                    throw CocoaError(.fileWriteUnknown)
                }
                output.frameLength = AVAudioFrameCount(count)
                for (stem, writer) in [instrumental, vocals].enumerated() {
                    for channel in 0..<2 {
                        for sample in 0..<count {
                            let index = offset + sample
                            destination[channel][sample] = overlap[stem][channel][index] /
                                max(weights[index], 1e-8)
                        }
                    }
                    try writer.write(from: output)
                }
                let percent = min(99, Int(Double(emitEnd) * 100 / Double(frameCount)))
                if percent > lastProgress { progress(percent); lastProgress = percent }
            }

            for channel in 0..<2 {
                incoming[channel].removeFirst(hop)
                incoming[channel].append(contentsOf: repeatElement(Float(0), count: hop))
            }
            try readSamples(min(hop, frameCount - readPosition), at: n - hop)
            for stem in 0..<2 {
                for channel in 0..<2 {
                    overlap[stem][channel].removeFirst(hop)
                    overlap[stem][channel].append(contentsOf: repeatElement(Float(0), count: hop))
                }
            }
            weights.removeFirst(hop)
            weights.append(contentsOf: repeatElement(Float(0), count: hop))
            frameStart += hop
        }
        progress(100)
    }
}
