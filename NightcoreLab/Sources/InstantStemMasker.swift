import Accelerate
import AudioToolbox
import AVFoundation

/// A zero-lookahead, analysis-only filterbank. The output is always the
/// original L/R sample multiplied by ONE nonnegative scalar: no L-R audio,
/// polarity inversion, delay line, or reconstruction summing is possible.
final class InstantStemMasker {
    static let rampSeconds = 0.05
    static let maximumFrames = 4_096

    private(set) var sampleRate: Double
    private var current: [Float] = [1, 1, 1, 1]
    private var target: [Float] = [1, 1, 1, 1]
    private var bassL = [Float](repeating: 0, count: 4)
    private var bassR = [Float](repeating: 0, count: 4)
    private var low220L: Float = 0, low220R: Float = 0
    private var low3800L: Float = 0, low3800R: Float = 0
    private var low2500L: Float = 0, low2500R: Float = 0
    private var fast: Float = 0, slow: Float = 0, coherence: Float = 0
    private let absL = UnsafeMutablePointer<Float>.allocate(capacity: maximumFrames)
    private let absR = UnsafeMutablePointer<Float>.allocate(capacity: maximumFrames)

    init(sampleRate: Double) { self.sampleRate = max(8_000, sampleRate) }
    deinit { absL.deallocate(); absR.deallocate() }

    func configure(sampleRate: Double) { self.sampleRate = max(8_000, sampleRate) }

    func set(_ kind: StemKind, level: Float) {
        target[Self.index(kind)] = min(2, max(0, level.isFinite ? level : 1))
    }

    var isDirect: Bool { current.allSatisfy { $0 == 1 } && target.allSatisfy { $0 == 1 } }

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
        let count = min(frames, Self.maximumFrames)
        if isDirect { return } // bit-transparent; never touch either buffer
        vDSP_vabs(left, 1, absL, 1, vDSP_Length(count))
        vDSP_vabs(right, 1, absR, 1, vDSP_Length(count))

        let rate = Float(sampleRate)
        let a145 = 1 - exp(-2 * Float.pi * 145 / rate)
        let a220 = 1 - exp(-2 * Float.pi * 220 / rate)
        let a2500 = 1 - exp(-2 * Float.pi * 2_500 / rate)
        let a3800 = 1 - exp(-2 * Float.pi * 3_800 / rate)
        let aFast = 1 - exp(-1 / (0.0012 * rate))
        let aSlow = 1 - exp(-1 / (0.035 * rate))
        let aPan = 1 - exp(-1 / (0.006 * rate))
        let ramp = 1 / max(1, Float(Self.rampSeconds) * rate)

        for n in 0..<count {
            for k in 0..<4 {
                let delta = target[k] - current[k]
                current[k] += min(ramp, max(-ramp, delta))
            }
            let l = left[n], r = right[n]
            let amplitude = 0.5 * (absL[n] + absR[n])
            for k in 0..<4 {
                bassL[k] += a145 * ((k == 0 ? l : bassL[k - 1]) - bassL[k])
                bassR[k] += a145 * ((k == 0 ? r : bassR[k - 1]) - bassR[k])
            }
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
            let instantC = 2 * abs(formantL * formantR) /
                (formantL * formantL + formantR * formantR + 1e-6)
            coherence += aPan * (instantC - coherence)
            let denominator = amplitude + 1e-5
            let bassWeight = min(0.92, max(0,
                (abs(bassL[3]) + abs(bassR[3])) * 0.5 / denominator))
            let highEnergy = (abs(l - low2500L) + abs(r - low2500R)) * 0.5
            let transient = max(0, (fast - slow) / (fast + 1e-5))
            let drumWeight = min(0.82, transient *
                (0.35 + 0.65 * min(1, highEnergy / denominator)))
            let formantEnergy = (abs(formantL) + abs(formantR)) * 0.5
            let vocalWeight = coherence > 0.78
                ? min(0.9, (coherence - 0.78) / 0.22) *
                    min(1, formantEnergy / denominator) : 0
            let gain = Self.gain(levels: current, bass: bassWeight,
                                 drums: drumWeight, vocal: vocalWeight)
            left[n] = l * gain
            right[n] = r * gain
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
