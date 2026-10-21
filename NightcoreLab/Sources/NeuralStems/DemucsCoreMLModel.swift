import Accelerate
import CoreML
import Foundation

public enum NeuralStemError: Error, LocalizedError {
    case modelMissing, incompatibleModel, invalidOutput, noAudio, insufficientSpace, insufficientMemory
    case memoryBudget(requiredMiB: Int, availableMiB: Int)
    public var errorDescription: String? {
        switch self {
        case .modelMissing: return "O modelo de separação não está incluído nesta versão do app."
        case .incompatibleModel: return "O modelo de separação é incompatível com esta versão."
        case .invalidOutput: return "Não foi possível gerar stems válidos neste aparelho."
        case .noAudio: return "A música não contém áudio compatível para separar."
        case .memoryBudget(let required, let available): return "A separação precisa de \(required) MB livres nesta etapa; há \(available) MB disponíveis. Aguarde um pouco e toque em Separar música para tentar novamente."
        case .insufficientMemory: return "O iPhone precisou liberar memória. Aguarde um pouco e toque em Separar música para tentar novamente."
        case .insufficientSpace: return "Libere espaço no iPhone para salvar as faixas separadas."
        }
    }
}

/// HTDemucs' real-valued neural core. STFT/iSTFT stay in Accelerate; no
/// spectral proxy or original-audio gain mask participates in separation.
/// One worker owns this instance and invokes predictions serially.
public final class DemucsCoreMLModel {
    public static let identifier = "htdemucs-v4-staged-fp32-tiled-v2"
    public static let sources = ["drums", "bass", "other", "vocals"]
    private let pipeline: StagedDemucsPipeline
    private var usingCPU: Bool
    public var lastModelLoadCount: Int { pipeline.modelLoadCount }

    /// A12 / 3–4GB devices cannot afford GPU graph specialization plus the
    /// full-precision model. Keep the identical validated model on the CPU.
    public static func prefersCPU(physicalMemory: UInt64) -> Bool {
        physicalMemory <= 4 * 1_024 * 1_024 * 1_024
    }

    public init(url: URL, cpuOnly: Bool = false) throws {
        pipeline = try StagedDemucsPipeline(root: url)
        #if targetEnvironment(simulator)
        usingCPU = true
        #else
        usingCPU = cpuOnly || Self.prefersCPU(physicalMemory: ProcessInfo.processInfo.physicalMemory)
        #endif
    }

    /// Planar stereo, exactly 343980 samples/channel → [source][channel][sample].
    public func separate(_ input: [Float], check: () throws -> Void = {},
                         admission: (Int) throws -> Void = { _ in },
                         progress: (Double, String) -> Void = { _, _ in }) throws -> [Float] {
        guard input.count == 2 * StemDSP.segmentSamples else { throw NeuralStemError.noAudio }
        do { return try predict(input, check: check, admission: admission, progress: progress) }
        catch NeuralStemError.invalidOutput where !usingCPU {
            usingCPU = true
            return try predict(input, check: check, admission: admission, progress: progress)
        }
    }

    private func predict(_ input: [Float], check: () throws -> Void,
                         admission: (Int) throws -> Void,
                         progress: (Double, String) -> Void) throws -> [Float] {
        try check()
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
        let output = try pipeline.run(mix: mix, spectrum: spectrum, cpuOnly: usingCPU,
                                      check: check, admission: admission, progress: progress)
        try check()
        guard let spec = output["frequency"], let time = output["time"] else { throw NeuralStemError.invalidOutput }
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
        let rowStride = strides[strides.count - 2], step = strides.last!
        // Resolve Core ML's Objective-C pointer once, not millions of times
        // per segment. Contiguous rows are copied in bulk without arithmetic.
        let data = array.dataPointer, isFloat = array.dataType == .float32
        result.withUnsafeMutableBufferPointer { destination in
            for row in 0..<rows {
                let offset = base + row * rowStride
                if isFloat, step == 1 {
                    destination.baseAddress!.advanced(by: row * columns).update(
                        from: data.assumingMemoryBound(to: Float.self) + offset, count: columns)
                } else {
                    for column in 0..<columns {
                        destination[row * columns + column] = isFloat
                            ? data.assumingMemoryBound(to: Float.self)[offset + column * step]
                            : Float(Float16(bitPattern: data.assumingMemoryBound(to: UInt16.self)[offset + column * step]))
                    }
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
        values.withUnsafeBufferPointer { source in
            for row in 0..<shape[shape.count - 2] {
                let offset = base + row * strides[strides.count - 2]
                if strides.last == 1 {
                    pointer.advanced(by: offset).update(from: source.baseAddress! + row * columns, count: columns)
                } else {
                    for column in 0..<columns { pointer[offset + column * strides.last!] = source[row * columns + column] }
                }
            }
        }
    }

    public static func writeStrided(_ values: [Float], to array: MLMultiArray) throws {
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        guard array.dataType == .float32, shape.reduce(1, *) == values.count,
              let inner = shape.last, inner > 0 else { throw NeuralStemError.incompatibleModel }
        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        values.withUnsafeBufferPointer { source in
        for row in 0..<(values.count / inner) {
            var base = 0, remaining = row
            for dim in stride(from: shape.count - 2, through: 0, by: -1) {
                base += (remaining % shape[dim]) * strides[dim]; remaining /= shape[dim]
            }
            if strides.last == 1 {
                pointer.advanced(by: base).update(from: source.baseAddress! + row * inner, count: inner)
            } else {
                for i in 0..<inner { pointer[base + i * strides.last!] = source[row * inner + i] }
            }
        }
        }
    }

    /// Core ML fp16 tensors can have padded rows (e.g. 344000 vs 343980).
    /// Respect EVERY stride and fail closed on unsupported types.
    public static func readStrided(_ array: MLMultiArray) throws -> [Float] {
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        guard let inner = shape.last, inner > 0 else { throw NeuralStemError.invalidOutput }
        let count = shape.reduce(1, *), rows = count / inner
        var result = [Float](repeating: 0, count: count)
        let data = array.dataPointer, kind = array.dataType
        guard kind == .float32 || kind == .float16 || kind == .double else { throw NeuralStemError.invalidOutput }
        result.withUnsafeMutableBufferPointer { destination in
        for row in 0..<rows {
            var base = 0, remaining = row
            for dim in stride(from: shape.count - 2, through: 0, by: -1) {
                base += (remaining % shape[dim]) * strides[dim]; remaining /= shape[dim]
            }
            let step = strides.last!
            switch kind {
            case .float32:
                let pointer = data.assumingMemoryBound(to: Float.self)
                if step == 1 {
                    destination.baseAddress!.advanced(by: row * inner).update(from: pointer + base, count: inner)
                } else {
                    for i in 0..<inner { destination[row * inner + i] = pointer[base + i * step] }
                }
            case .float16:
                let pointer = data.assumingMemoryBound(to: UInt16.self)
                for i in 0..<inner { destination[row * inner + i] = Float(Float16(bitPattern: pointer[base + i * step])) }
            case .double:
                let pointer = data.assumingMemoryBound(to: Double.self)
                for i in 0..<inner { destination[row * inner + i] = Float(pointer[base + i * step]) }
            default: break // Rejected above, before accessing storage.
            }
            }
        }
        return result
    }
}
