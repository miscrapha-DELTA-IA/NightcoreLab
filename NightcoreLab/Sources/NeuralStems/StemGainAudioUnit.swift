import AudioToolbox
import AVFoundation

/// A source's volume only. No audio-derived coefficient, classification,
/// cancellation or EQ: each input already IS a separately inferred stem.
final class LinearStemGain {
    private(set) var current: Float
    private var target: Float
    private var increment: Float = 0
    private var remaining = 0
    var sampleRate = 44_100.0
    init(_ initial: Float = 0) { current = initial; target = initial }
    func initialize(_ value: Float) { current = value; target = value; remaining = 0; increment = 0 }
    func set(_ value: Float) {
        target = min(2, max(0, value.isFinite ? value : 1))
        remaining = max(1, Int(sampleRate * 0.03))
        increment = (target - current) / Float(remaining)
    }
    func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>?, count: Int) {
        if remaining == 0 && current == 1 { return }
        for i in 0..<count {
            if remaining > 0 {
                current += increment; remaining -= 1
                if remaining == 0 { current = target }
            }
            left[i] *= current
            if let right { right[i] *= current }
        }
    }
}

final class StemGainAudioUnit: AUAudioUnit {
    private let input: AUAudioUnitBus
    private let output: AUAudioUnitBus
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    private let gain = LinearStemGain()
    private static let component = AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: 0x474E5347,
        componentManufacturer: 0x4E434C42, componentFlags: 0, componentFlagsMask: 0)
    private static let registration: Void = {
        AUAudioUnit.registerSubclass(StemGainAudioUnit.self, as: component,
            name: "Gnarly:Stem Volume", version: 1)
    }()
    static func makeNode(initialGain: Float = 0) -> AVAudioUnitEffect {
        _ = registration
        let node = AVAudioUnitEffect(audioComponentDescription: component)
        // Cold initialization, before attaching or rendering the node.
        (node.auAudioUnit as? StemGainAudioUnit)?.gain.initialize(initialGain)
        return node
    }
    /// Only before the graph starts rendering (offline graph setup).
    func initializeGain(_ value: Float) { gain.initialize(value) }
    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        input = try AUAudioUnitBus(format: format); output = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [input])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [output])
        maximumFramesToRender = 4096
    }
    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override func allocateRenderResources() throws {
        try super.allocateRenderResources(); gain.sampleRate = output.format.sampleRate
    }
    override var internalRenderBlock: AUInternalRenderBlock {
        let gain = self.gain
        return { flags, timestamp, frames, _, data, events, pull in
            guard let pull else { return kAudioUnitErr_NoConnection }
            let status = pull(flags, timestamp, frames, 0, data)
            guard status == noErr else { return status }
            var event = events
            while let e = event {
                if e.pointee.head.eventType == .parameter { gain.set(e.pointee.parameter.value) }
                event = e.pointee.head.next.map { UnsafePointer($0) }
            }
            let buffers = UnsafeMutableAudioBufferListPointer(data)
            guard buffers.count >= 2, let l = buffers[0].mData, let r = buffers[1].mData else {
                return kAudioUnitErr_FormatNotSupported
            }
            gain.process(l.assumingMemoryBound(to: Float.self), r.assumingMemoryBound(to: Float.self), count: Int(frames))
            return noErr
        }
    }
}

/// Four independent players in the EXISTING live engine, upstream of the
/// shared speed/pitch/EQ chain. The original player remains its clock source.
final class NeuralStemPlayback {
    private let players = StemKind.allCases.map { _ in AVAudioPlayerNode() }
    private let gains = StemKind.allCases.map { _ in StemGainAudioUnit.makeNode() }
    private var files: [AVAudioFile] = []
    private(set) var asset: StemAsset?
    var nodes: [AVAudioNode] { players.map { $0 as AVAudioNode } + gains.map { $0 as AVAudioNode } }
    func connect(engine: AVAudioEngine, mixer: AVAudioMixerNode) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        for i in players.indices {
            engine.connect(players[i], to: gains[i], format: format)
            engine.connect(gains[i], to: mixer, format: format)
        }
    }
    func load(_ asset: StemAsset, seconds: Double) throws {
        _ = try NeuralStemWorker.validate(asset, expectedSeconds: seconds)
        let opened = try StemKind.allCases.map {
            try AVAudioFile(forReading: asset.urls[$0]!, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        stop(); files = opened; self.asset = asset
    }
    func clear() { stop(); files = []; asset = nil }
    func schedule(at seconds: Double) {
        stop()
        for (player, file) in zip(players, files) {
            let start = min(file.length, max(0, AVAudioFramePosition(seconds * file.processingFormat.sampleRate)))
            if start < file.length {
                player.scheduleSegment(file, startingFrame: start,
                    frameCount: AVAudioFrameCount(min(file.length - start, Int64(UInt32.max))), at: nil)
            }
        }
    }
    func play(at time: AVAudioTime?) { if asset != nil { players.forEach { $0.play(at: time) } } }
    func pause() { players.forEach { $0.pause() } }
    func stop() { players.forEach { $0.stop() } }
    func setLevels(_ levels: [StemKind: Float], enabled: Bool, immediate: Bool = false) {
        for (i, kind) in StemKind.allCases.enumerated() {
            let value: Float = enabled && asset != nil ? (levels[kind] ?? 1) : 0
            if immediate, let unit = gains[i].auAudioUnit as? StemGainAudioUnit {
                unit.initializeGain(value)
            } else {
                gains[i].auAudioUnit.scheduleParameterBlock(AUEventSampleTimeImmediate, 0, 0, value)
            }
        }
    }
}
