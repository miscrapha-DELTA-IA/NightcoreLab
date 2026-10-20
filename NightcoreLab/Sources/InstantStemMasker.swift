import AudioToolbox
import AVFoundation

/// A zero-lookahead, analysis-only filterbank. The output is always the
/// original L/R sample multiplied by ONE nonnegative scalar: no L-R audio,
/// polarity inversion, delay line, or reconstruction summing is possible.
final class InstantStemMasker {
    static let rampSeconds = 0.05
    static let maximumFrames = 4_096

    /// Two identical 2nd-order Butterworth low-pass sections form an LR4
    /// 145 Hz analysis band. Its filtered signal never reaches the output.
    private struct BassBiquad {
        let b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
        var z1: Float = 0, z2: Float = 0

        init(rate: Double) {
            let k = Float(tan(.pi * 145 / rate))
            let root2 = Float(2).squareRoot()
            let normalizer = 1 / (1 + root2 * k + k * k)
            b0 = k * k * normalizer
            b1 = 2 * b0
            b2 = b0
            a1 = 2 * (k * k - 1) * normalizer
            a2 = (1 - root2 * k + k * k) * normalizer
        }

        mutating func process(_ sample: Float) -> Float {
            let output = b0 * sample + z1
            z1 = b1 * sample - a1 * output + z2
            z2 = b2 * sample - a2 * output
            return output
        }
    }

    private(set) var sampleRate: Double
    private var current: [Float] = [1, 1, 1, 1]
    private var target: [Float] = [1, 1, 1, 1]
    private var bassL1 = BassBiquad(rate: 44_100)
    private var bassL2 = BassBiquad(rate: 44_100)
    private var bassR1 = BassBiquad(rate: 44_100)
    private var bassR2 = BassBiquad(rate: 44_100)
    private var sub20L: Float = 0, sub20R: Float = 0
    private var low220L: Float = 0, low220R: Float = 0
    private var low3800L: Float = 0, low3800R: Float = 0
    private var low2500L: Float = 0, low2500R: Float = 0
    private var fast: Float = 0, slow: Float = 0
    private var inputPower: Float = 0, bassPower: Float = 0
    private var formantPower: Float = 0, highPower: Float = 0, centerPower: Float = 0
    private var bassMask: Float = 0, drumMask: Float = 0, vocalMask: Float = 0
    private var gainStage: Double = 1, outputGain: Double = 1

    init(sampleRate: Double) {
        self.sampleRate = max(8_000, sampleRate)
        configure(sampleRate: self.sampleRate)
    }

    func configure(sampleRate: Double) {
        self.sampleRate = max(8_000, sampleRate)
        bassL1 = BassBiquad(rate: self.sampleRate)
        bassL2 = BassBiquad(rate: self.sampleRate)
        bassR1 = BassBiquad(rate: self.sampleRate)
        bassR2 = BassBiquad(rate: self.sampleRate)
        sub20L = 0; sub20R = 0
        low220L = 0; low220R = 0; low3800L = 0; low3800R = 0
        low2500L = 0; low2500R = 0; fast = 0; slow = 0
        inputPower = 0; bassPower = 0; formantPower = 0; highPower = 0; centerPower = 0
        bassMask = 0; drumMask = 0; vocalMask = 0
    }

    func set(_ kind: StemKind, level: Float) {
        target[Self.index(kind)] = min(2, max(0, level.isFinite ? level : 1))
    }

    var isDirect: Bool {
        current.allSatisfy { $0 == 1 } && target.allSatisfy { $0 == 1 } &&
            gainStage == 1 && outputGain == 1
    }

    private static func index(_ kind: StemKind) -> Int {
        switch kind {
        case .vocal: return 0
        case .instrumental: return 1
        case .drums: return 2
        case .bass: return 3
        }
    }

    /// Positive, normalized partition; weights always sum to exactly one.
    /// Frequency filtering is used only to decide the weights, never to
    /// resynthesize audio, so the original stereo phase remains untouched.
    static func gain(levels: [Float], bass: Float, drums: Float,
                     vocal: Float) -> Float {
        let b = min(1, max(0, bass))
        let d = min(1 - b, max(0, drums))
        let v = min(1 - b - d, max(0, vocal))
        let i = max(0, 1 - b - d - v)
        return min(2, max(0, v * levels[0] + i * levels[1] +
                          d * levels[2] + b * levels[3]))
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                 frames: Int) {
        guard frames > 0 else { return }
        if isDirect { return } // bit-transparent; never touch either buffer

        let rate = Float(sampleRate)
        let a20 = 1 - exp(-2 * Float.pi * 20 / rate)
        let a220 = 1 - exp(-2 * Float.pi * 220 / rate)
        let a2500 = 1 - exp(-2 * Float.pi * 2_500 / rate)
        let a3800 = 1 - exp(-2 * Float.pi * 3_800 / rate)
        let aFast = 1 - exp(-1 / (0.0012 * rate))
        let aSlow = 1 - exp(-1 / (0.035 * rate))
        let aEnvelope = 1 - exp(-1 / (0.025 * rate))
        let aGain = 1 - exp(-1 / (0.01 * sampleRate))
        let ramp = 1 / max(1, Float(Self.rampSeconds) * rate)

        for n in 0..<frames {
            for k in 0..<4 {
                let delta = target[k] - current[k]
                current[k] += min(ramp, max(-ramp, delta))
            }
            let l = left[n], r = right[n]
            let amplitude = 0.5 * (abs(l) + abs(r))
            let bassStageL = bassL1.process(l)
            let bassStageR = bassR1.process(r)
            let bassSampleL = bassL2.process(bassStageL)
            let bassSampleR = bassR2.process(bassStageR)
            sub20L += a20 * (bassSampleL - sub20L)
            sub20R += a20 * (bassSampleR - sub20R)
            low220L += a220 * (l - low220L)
            low220R += a220 * (r - low220R)
            low3800L += a3800 * (l - low3800L)
            low3800R += a3800 * (r - low3800R)
            low2500L += a2500 * (l - low2500L)
            low2500R += a2500 * (r - low2500R)
            fast += aFast * (amplitude - fast)
            slow += aSlow * (amplitude - slow)

            let formantL = low3800L - low220L
            let formantR = low3800R - low220R
            let bassL = bassSampleL - sub20L, bassR = bassSampleR - sub20R
            let highL = l - low2500L, highR = r - low2500R
            // Ratios of instantaneous rectified samples explode at waveform
            // zero crossings. Their audio-rate gain modulation was audible as
            // buzz/hiss. Measure power envelopes before calculating any ratio.
            inputPower += aEnvelope * (0.5 * (l * l + r * r) - inputPower)
            bassPower += aEnvelope * (0.5 * (bassL * bassL + bassR * bassR) - bassPower)
            formantPower += aEnvelope * (0.5 * (formantL * formantL + formantR * formantR) - formantPower)
            highPower += aEnvelope * (0.5 * (highL * highL + highR * highR) - highPower)
            centerPower += aEnvelope * (formantL * formantR - centerPower)
            let denominator = max(inputPower, 1e-8)
            let bassWeight = min(0.92, sqrt(max(0, bassPower) / denominator))
            let highWeight = min(1, sqrt(max(0, highPower) / denominator))
            let transient = max(0, (fast - slow) / (fast + 1e-5))
            let drumWeight = min(0.82, transient * (0.35 + 0.65 * highWeight))
            let coherence = min(1, max(0, centerPower / max(formantPower, 1e-8)))
            let vocalWeight = min(0.9, max(0, (coherence - 0.78) / 0.22)) *
                min(1, sqrt(max(0, formantPower) / denominator))
            // Mask decisions and output gain are control signals, not audio.
            // Smooth both to suppress harmonic/intermodulation sidebands. One
            // shared positive gain preserves the original stereo relationship.
            bassMask += aEnvelope * (bassWeight - bassMask)
            drumMask += aEnvelope * (drumWeight - drumMask)
            vocalMask += aEnvelope * (vocalWeight - vocalMask)
            let equalLevels = current[0] == current[1] && current[1] == current[2] && current[2] == current[3]
            let desired = Double(equalLevels ? current[0] :
                Self.gain(levels: current, bass: bassMask, drums: drumMask, vocal: vocalMask))
            gainStage += aGain * (desired - gainStage)
            outputGain += aGain * (gainStage - outputGain)
            if equalLevels && abs(gainStage - desired) < 1e-7 && abs(outputGain - desired) < 1e-7 {
                // Settle exactly before entering the bit-transparent bypass;
                // never jump from a still-attenuated tail to unity next block.
                gainStage = desired; outputGain = desired
            }
            left[n] = l * Float(outputGain)
            right[n] = r * Float(outputGain)
        }
    }
}

/// In-process AUv3 effect keeps the existing AVAudioPlayerNode as transport.
/// Parameter changes arrive on the audio render thread as scheduled AU events.
final class InstantStemAudioUnit: AUAudioUnit {
    private let input: AUAudioUnitBus
    private let output: AUAudioUnitBus
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    private let masker = InstantStemMasker(sampleRate: 44_100)

    static let description = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x4E43534D, // NCSM
        componentManufacturer: 0x4E434C42, // NCLB
        componentFlags: 0, componentFlagsMask: 0)

    private static let registration: Void = {
        AUAudioUnit.registerSubclass(InstantStemAudioUnit.self, as: description,
                                     name: "NightcoreLab:Instant Stems", version: 1)
    }()

    static func makeNode() -> AVAudioUnitEffect {
        _ = registration
        return AVAudioUnitEffect(audioComponentDescription: description)
    }

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        input = try AUAudioUnitBus(format: format)
        output = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [input])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [output])
        maximumFramesToRender = AUAudioFrameCount(InstantStemMasker.maximumFrames)
    }

    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        masker.configure(sampleRate: output.format.sampleRate)
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let masker = self.masker
        return { flags, timestamp, frames, _, outputData, events, pullInput in
            guard let pullInput else { return kAudioUnitErr_NoConnection }
            let status = pullInput(flags, timestamp, frames, 0, outputData)
            guard status == noErr else { return status }
            var event = events
            while let current = event {
                if current.pointee.head.eventType == .parameter {
                    let parameter = current.pointee.parameter
                    let kind: StemKind?
                    switch parameter.parameterAddress {
                    case 0: kind = .vocal
                    case 1: kind = .instrumental
                    case 2: kind = .drums
                    case 3: kind = .bass
                    default: kind = nil
                    }
                    if let kind { masker.set(kind, level: parameter.value) }
                }
                event = current.pointee.head.next.map { UnsafePointer($0) }
            }
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard buffers.count >= 2,
                  let leftData = buffers[0].mData,
                  let rightData = buffers[1].mData else { return noErr }
            masker.process(left: leftData.assumingMemoryBound(to: Float.self),
                           right: rightData.assumingMemoryBound(to: Float.self),
                           frames: Int(frames))
            return noErr
        }
    }
}
