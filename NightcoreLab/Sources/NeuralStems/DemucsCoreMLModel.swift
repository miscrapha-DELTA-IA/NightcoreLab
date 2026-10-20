import Accelerate
import CoreML
import Foundation

public enum NeuralStemError: Error, LocalizedError {
    case modelMissing, incompatibleModel, invalidOutput, noAudio, insufficientSpace, insufficientMemory
    public var errorDescription: String? {
        switch self {
        case .modelMissing: return "O modelo de separação não está incluído nesta versão do app."
        case .incompatibleModel: return "O modelo de separação é incompatível com esta versão."
        case .invalidOutput: return "Não foi possível gerar stems válidos neste aparelho."
        case .noAudio: return "A música não contém áudio compatível para separar."
        case .insufficientMemory: return "O iPhone está com pouca memória para separar esta música agora. Tente novamente após reabrir o app."
        case .insufficientSpace: return "Libere espaço no iPhone para salvar as faixas separadas."
        }
    }
}

/// HTDemucs' real-valued neural core. STFT/iSTFT stay in Accelerate; no
/// spectral proxy or original-audio gain mask participates in separation.
/// One worker owns this instance and invokes predictions serially.
public final class DemucsCoreMLModel {
    public static let identifier = "htdemucs-v4-core-fp32-v1"
    public static let sources = ["drums", "bass", "other", "vocals"]
    private let url: URL
    private var model: MLModel
    private var usingCPU: Bool
    private let mixName: String
    private let specName: String

    /// A12 / 3–4GB devices cannot afford GPU graph specialization plus the
    /// full-precision model. Keep the identical validated model on the CPU.
    public static func prefersCPU(physicalMemory: UInt64) -> Bool {
        physicalMemory <= 4 * 1_024 * 1_024 * 1_024
    }

    public init(url: URL, cpuOnly: Bool = false) throws {
        self.url = url
        #if targetEnvironment(simulator)
        usingCPU = true
        #else
        usingCPU = cpuOnly || Self.prefersCPU(physicalMemory: ProcessInfo.processInfo.physicalMemory)
        #endif
        let config = MLModelConfiguration()
        // The ANE is deliberately excluded for this graph; some paths produce
        // invalid spectral outputs. Simulator GPU is not a valid test backend.
        config.computeUnits = usingCPU ? .cpuOnly : .cpuAndGPU
        model = try MLModel(contentsOf: url, configuration: config)
        let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        guard metadata["gnarly.model_id"] == Self.identifier,
              metadata["sources"] == Self.sources.joined(separator: ","),
              metadata["segment_samples"] == String(StemDSP.segmentSamples) else {
            throw NeuralStemError.incompatibleModel
        }
        let inputs = model.modelDescription.inputDescriptionsByName
        guard let mix = inputs.first(where: { $0.value.multiArrayConstraint?.shape.map(\.intValue) == [1, 2, StemDSP.segmentSamples] }),
              let spec = inputs.first(where: { $0.value.multiArrayConstraint?.shape.map(\.intValue) == [1, 4, StemDSP.bins, StemDSP.frames] }) else {
            throw NeuralStemError.incompatibleModel
        }
        mixName = mix.key; specName = spec.key
    }

    /// Planar stereo, exactly 343980 samples/channel → [source][channel][sample].
    public func separate(_ input: [Float]) throws -> [Float] {
        guard input.count == 2 * StemDSP.segmentSamples else { throw NeuralStemError.noAudio }
        do { return try predict(input) }
        catch NeuralStemError.invalidOutput where !usingCPU {
            // A device-specific GPU failure must never become silent/fake stems.
            let config = MLModelConfiguration(); config.computeUnits = .cpuOnly
            model = try MLModel(contentsOf: url, configuration: config)
            usingCPU = true
            return try predict(input)
        }
    }

    private func predict(_ input: [Float]) throws -> [Float] {
        try Task.checkCancellation()
        let length = StemDSP.segmentSamples
        let mix = try MLMultiArray(shape: [1, 2, NSNumber(value: length)], dataType: .float32)
        let spectrum = try MLMultiArray(shape: [1, 4, NSNumber(value: StemDSP.bins), NSNumber(value: StemDSP.frames)], dataType: .float32)
        try Self.writeStrided(input, to: mix)
        for channel in 0..<2 {
            let signal = Array(input[(channel * length)..<((channel + 1) * length)])
            let spec = StemDSP.stft(signal)
            try Self.writePlane(spec.re, to: spectrum, prefix: [0, channel * 2])
            try Self.writePlane(spec.im, to: spectrum, prefix: [0, channel * 2 + 1])
        }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [mixName: mix, specName: spectrum]))
        try Task.checkCancellation()
        let arrays = output.featureNames.compactMap { output.featureValue(for: $0)?.multiArrayValue }
        guard let spec = arrays.first(where: { $0.shape.map(\.intValue) == [1, 4, 4, StemDSP.bins, StemDSP.frames] }),
              let time = arrays.first(where: { $0.shape.map(\.intValue) == [1, 4, 2, length] }) else {
            throw NeuralStemError.incompatibleModel
        }
        var result = try Self.readStrided(time)
        for source in 0..<4 {
            for channel in 0..<2 {
                // Read one complex plane at a time. Flattening all four
                // frequency sources duplicated another 44MB per prediction.
                let wave = StemDSP.istft(
                    re: try Self.readPlane(spec, prefix: [0, source, channel * 2]),
                    im: try Self.readPlane(spec, prefix: [0, source, channel * 2 + 1]))
                let target = (source * 2 + channel) * length
                result.withUnsafeMutableBufferPointer { r in
                    wave.withUnsafeBufferPointer { w in
                        vDSP_vadd(r.baseAddress! + target, 1, w.baseAddress!, 1,
                                  r.baseAddress! + target, 1, vDSP_Length(length))
                    }
                }
            }
        }
        guard result.allSatisfy({ $0.isFinite && abs($0) < 100 }) else { throw NeuralStemError.invalidOutput }
        if input.contains(where: { abs($0) > 0.001 }) && !result.contains(where: { abs($0) > 0.000001 }) {
            throw NeuralStemError.invalidOutput
        }
        return result
    }

    /// Last two dimensions, respecting padding in both dimensions and prefix.
    public static func readPlane(_ array: MLMultiArray, prefix: [Int]) throws -> [Float] {
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        guard prefix.count == shape.count - 2,
              zip(prefix, shape).allSatisfy({ $0.0 >= 0 && $0.0 < $0.1 }),
              array.dataType == .float32 || array.dataType == .float16 else { throw NeuralStemError.invalidOutput }
        let rows = shape[shape.count - 2], columns = shape.last!
        let base = zip(prefix, strides).reduce(0) { $0 + $1.0 * $1.1 }
        var result = [Float](repeating: 0, count: rows * columns)
        for row in 0..<rows {
            for column in 0..<columns {
                let offset = base + row * strides[strides.count - 2] + column * strides.last!
                if array.dataType == .float32 {
                    result[row * columns + column] = array.dataPointer.assumingMemoryBound(to: Float.self)[offset]
                } else {
                    result[row * columns + column] = Float(Float16(bitPattern: array.dataPointer.assumingMemoryBound(to: UInt16.self)[offset]))
                }
            }
        }
        return result
    }

    public static func writePlane(_ values: [Float], to array: MLMultiArray, prefix: [Int]) throws {
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        guard prefix.count == shape.count - 2,
              zip(prefix, shape).allSatisfy({ $0.0 >= 0 && $0.0 < $0.1 }), array.dataType == .float32,
              values.count == shape[shape.count - 2] * shape.last! else { throw NeuralStemError.incompatibleModel }
        let columns = shape.last!, base = zip(prefix, strides).reduce(0) { $0 + $1.0 * $1.1 }
        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        for row in 0..<shape[shape.count - 2] {
            for column in 0..<columns {
                pointer[base + row * strides[strides.count - 2] + column * strides.last!] = values[row * columns + column]
            }
        }
    }

    public static func writeStrided(_ values: [Float], to array: MLMultiArray) throws {
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        guard array.dataType == .float32, shape.reduce(1, *) == values.count,
              let inner = shape.last, inner > 0 else { throw NeuralStemError.incompatibleModel }
        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        for row in 0..<(values.count / inner) {
            var base = 0, remaining = row
            for dim in stride(from: shape.count - 2, through: 0, by: -1) {
                base += (remaining % shape[dim]) * strides[dim]; remaining /= shape[dim]
            }
            for i in 0..<inner { pointer[base + i * strides.last!] = values[row * inner + i] }
        }
    }

    /// Core ML fp16 tensors can have padded rows (e.g. 344000 vs 343980).
    /// Respect EVERY stride and fail closed on unsupported types.
    public static func readStrided(_ array: MLMultiArray) throws -> [Float] {
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        guard let inner = shape.last, inner > 0 else { throw NeuralStemError.invalidOutput }
        let count = shape.reduce(1, *), rows = count / inner
        var result = [Float](repeating: 0, count: count)
        for row in 0..<rows {
            var base = 0, remaining = row
            for dim in stride(from: shape.count - 2, through: 0, by: -1) {
                base += (remaining % shape[dim]) * strides[dim]; remaining /= shape[dim]
            }
            let step = strides.last!
            switch array.dataType {
            case .float32:
                let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
                for i in 0..<inner { result[row * inner + i] = pointer[base + i * step] }
            case .float16:
                let pointer = array.dataPointer.assumingMemoryBound(to: UInt16.self)
                for i in 0..<inner { result[row * inner + i] = Float(Float16(bitPattern: pointer[base + i * step])) }
            case .double:
                let pointer = array.dataPointer.assumingMemoryBound(to: Double.self)
                for i in 0..<inner { result[row * inner + i] = Float(pointer[base + i * step]) }
            default: throw NeuralStemError.invalidOutput
            }
        }
        return result
    }
}
