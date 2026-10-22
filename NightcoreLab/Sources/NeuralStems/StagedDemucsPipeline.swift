import CoreML
import Foundation

/// One Core ML model at a time. Owned output copies cannot retain a previous
/// model's weights, execution plan or prediction scratch. Dead skip tensors
/// are released immediately after their final consumer.
final class StagedDemucsPipeline {
    struct Instruction: Decodable {
        let name: String
        let kind: String
        let inputs: [String]
        let outputs: [String]
        let inputShapes: [[Int]]
        let outputShapes: [[Int]]
        let workingMemoryBytes: Int?
    }
    struct Manifest: Decodable {
        let modelId: String
        let sources: [String]
        let segmentSamples: Int
        let attentionQueryBlock: Int
        let stageHeadroomBytes: Int
        let spectralTileRows: Int
        let spectralHaloRows: Int
        let stages: [Instruction]
    }
    let manifest: Manifest
    private let root: URL
    private(set) var modelLoadCount = 0

    init(root: URL) throws {
        self.root = root
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("pipeline.json")))
        guard manifest.modelId == DemucsCoreMLModel.identifier,
              manifest.sources == DemucsCoreMLModel.sources,
              manifest.segmentSamples == StemDSP.segmentSamples,
              manifest.attentionQueryBlock == BlockedAttention.blockRows,
              manifest.spectralTileRows == 32, manifest.spectralHaloRows == 2,
              manifest.stages.count == 29 else { throw NeuralStemError.incompatibleModel }
        for stage in manifest.stages {
            guard !stage.name.isEmpty, stage.name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
                  stage.inputs.count == stage.inputShapes.count,
                  stage.outputs.count == stage.outputShapes.count else { throw NeuralStemError.incompatibleModel }
            if stage.kind == "coreml" {
                guard FileManager.default.fileExists(atPath: root.appendingPathComponent(stage.name + ".mlmodelc").path)
                else { throw NeuralStemError.modelMissing }
            } else if stage.kind == "spectral_decode" {
                for variant in ["edge", "inner"] {
                    guard FileManager.default.fileExists(atPath: root.appendingPathComponent(stage.name + "_" + variant + ".mlmodelc").path)
                    else { throw NeuralStemError.modelMissing }
                }
            } else if stage.kind != "attention" { throw NeuralStemError.incompatibleModel }
        }
    }

    func run(mix: MLMultiArray, spectrum: MLMultiArray, cpuOnly: Bool,
             check: () throws -> Void, admission: (Int) throws -> Void,
             progress: (Double, String) -> Void) throws -> [String: MLMultiArray] {
        modelLoadCount = 0
        var state = ["mix": mix, "spec": spectrum]
        var remaining: [String: Int] = [:]
        for instruction in manifest.stages {
            for input in instruction.inputs { remaining[input, default: 0] += 1 }
        }
        for (index, instruction) in manifest.stages.enumerated() {
            try check()
            try admission(instruction.workingMemoryBytes ?? manifest.stageHeadroomBytes)
            let output: [MLMultiArray] = try autoreleasepool {
                let input = try instruction.inputs.enumerated().map { i, key -> MLMultiArray in
                    guard let tensor = state[key], tensor.shape.map(\.intValue) == instruction.inputShapes[i]
                    else { throw NeuralStemError.incompatibleModel }
                    return tensor
                }
                if instruction.kind == "attention" {
                    guard input.count == 6 else { throw NeuralStemError.incompatibleModel }
                    return try [0, 3].map { offset in
                        let shape = input[offset].shape.map(\.intValue)
                        guard shape.count == 4, shape[0] == 1 else { throw NeuralStemError.incompatibleModel }
                        let values = try BlockedAttention.evaluate(
                            query: DemucsCoreMLModel.readStrided(input[offset]),
                            key: DemucsCoreMLModel.readStrided(input[offset + 1]),
                            value: DemucsCoreMLModel.readStrided(input[offset + 2]),
                            heads: shape[1], queries: shape[2], keys: input[offset + 1].shape[2].intValue,
                            width: shape[3], check: check)
                        let tensor = try MLMultiArray(shape: input[offset].shape, dataType: .float32)
                        try DemucsCoreMLModel.writeStrided(values, to: tensor)
                        return tensor
                    }
                }
                if instruction.kind == "spectral_decode" {
                    return [try tiledSpectral(instruction, input: input, cpuOnly: cpuOnly,
                                              check: check, admission: admission)]
                }
                return try predict(name: instruction.name, input: input, outputShapes: instruction.outputShapes,
                                   cpuOnly: cpuOnly, check: check)
            }
            for (key, tensor) in zip(instruction.outputs, output) { state[key] = tensor }
            for key in instruction.inputs {
                remaining[key, default: 0] -= 1
                if remaining[key] == 0 { state[key] = nil }
            }
            progress(Double(index + 1) / Double(manifest.stages.count), instruction.name)
        }
        guard let frequency = state["frequency"], let time = state["time"] else { throw NeuralStemError.invalidOutput }
        return ["frequency": frequency, "time": time]
    }

    private func predict(name: String, input: [MLMultiArray], outputShapes: [[Int]],
                         cpuOnly: Bool, check: () throws -> Void) throws -> [MLMultiArray] {
        let model = try loadModel(name: name, cpuOnly: cpuOnly)
        return try predict(model: model, input: input, outputShapes: outputShapes, check: check)
    }

    private func loadModel(name: String, cpuOnly: Bool) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = cpuOnly ? .cpuOnly : .cpuAndGPU
        let model = try MLModel(contentsOf: root.appendingPathComponent(name + ".mlmodelc"), configuration: configuration)
        let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        guard metadata["gnarly.model_id"] == DemucsCoreMLModel.identifier,
              metadata["gnarly.stage"] == name else { throw NeuralStemError.incompatibleModel }
        modelLoadCount += 1
        return model
    }

    private func predict(model: MLModel, input: [MLMultiArray], outputShapes: [[Int]],
                         check: () throws -> Void) throws -> [MLMultiArray] {
        var feed: [String: MLMultiArray] = [:]
        for i in input.indices {
            let key = "input_\(i)"
            if let description = model.modelDescription.inputDescriptionsByName[key] {
                guard description.multiArrayConstraint?.shape == input[i].shape else { throw NeuralStemError.incompatibleModel }
                feed[key] = input[i]
            }
        }
        guard feed.count == model.modelDescription.inputDescriptionsByName.count else { throw NeuralStemError.incompatibleModel }
        let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: feed))
        try check()
        return try outputShapes.indices.map { i in
            guard let tensor = prediction.featureValue(for: "output_\(i)")?.multiArrayValue,
                  tensor.shape.map(\.intValue) == outputShapes[i] else { throw NeuralStemError.incompatibleModel }
            return try Self.ownedCopy(tensor)
        }
    }

    struct SpectralTile: Equatable {
        let start: Int, end: Int, lower: Int, upper: Int
        var variant: String { upper - lower == 34 ? "edge" : "inner" }
    }

    /// Edge tiles are independent of one another and of the interior tiles.
    /// Grouping them permits ONE loaded model at a time, reused for all tiles
    /// of that shape. The full-context outputs still go to their original rows.
    static func spectralTiles(frequencies: Int) -> [SpectralTile] {
        stride(from: 0, to: frequencies, by: 32).map { start in
            let end = min(frequencies, start + 32)
            return SpectralTile(start: start, end: end, lower: max(0, start - 2),
                                upper: min(frequencies, end + 2))
        }
    }

    /// The large decoder rewrite is a 3x3 spectral convolution. Frequency
    /// tiles have TWO input halo rows: one for rewrite, one for the overlapping
    /// stride4/kernel8 transpose convolution. Full time context is preserved.
    /// Edge models use34 rows; interior models36. No fake padded neurons.
    private func tiledSpectral(_ stage: Instruction, input: [MLMultiArray], cpuOnly: Bool,
                               check: () throws -> Void, admission: (Int) throws -> Void) throws -> MLMultiArray {
        guard input.count == 3, stage.outputShapes.count == 1 else { throw NeuralStemError.incompatibleModel }
        let result = try MLMultiArray(shape: stage.outputShapes[0].map { NSNumber(value: $0) }, dataType: .float32)
        let frequencies = input[0].shape[input[0].shape.count - 2].intValue
        let tiles = Self.spectralTiles(frequencies: frequencies)
        for variant in ["edge", "inner"] {
            try check()
            try admission(96 * 1_024 * 1_024)
            try autoreleasepool {
                let model = try loadModel(name: stage.name + "_" + variant, cpuOnly: cpuOnly)
                for tileRange in tiles where tileRange.variant == variant {
                    try check()
                    try admission(96 * 1_024 * 1_024)
                    try autoreleasepool {
                        let start = tileRange.start, end = tileRange.end
                        let lo = tileRange.lower, hi = tileRange.upper
                        let tile = try [0, 1].map { i -> MLMultiArray in
                            var shape = input[i].shape
                            shape[shape.count - 2] = NSNumber(value: hi - lo)
                            let tensor = try MLMultiArray(shape: shape, dataType: .float32)
                            try Self.copyFrequencies(input[i], start: lo, count: hi - lo, to: tensor, at: 0)
                            return tensor
                        } + [input[2]]
                        var shape = stage.outputShapes[0]
                        shape[shape.count - 2] = (hi - lo) * 4
                        let output = try predict(model: model, input: tile, outputShapes: [shape], check: check)[0]
                        try Self.copyFrequencies(output, start: (start - lo) * 4, count: (end - start) * 4,
                                                 to: result, at: start * 4)
                    }
                }
            }
        }
        return result
    }

    /// All tensors have frequency on their penultimate axis, including the
    /// final [batch,source,complex_channel,frequency,time] tensor.
    static func copyFrequencies(_ source: MLMultiArray, start: Int, count: Int,
                                to destination: MLMultiArray, at target: Int) throws {
        let shape = source.shape.map(\.intValue), targetShape = destination.shape.map(\.intValue)
        let src = source.strides.map(\.intValue), dst = destination.strides.map(\.intValue)
        guard shape.count >= 2, shape.count == targetShape.count,
              source.dataType == .float32, destination.dataType == .float32 else { throw NeuralStemError.incompatibleModel }
        let axis = shape.count - 2
        guard start >= 0, count > 0, start + count <= shape[axis], target >= 0, target + count <= targetShape[axis],
              shape.indices.allSatisfy({ $0 == axis || shape[$0] == targetShape[$0] }) else { throw NeuralStemError.incompatibleModel }
        let sourceData = source.dataPointer.assumingMemoryBound(to: Float.self)
        let targetData = destination.dataPointer.assumingMemoryBound(to: Float.self)
        let lanes = shape.prefix(axis).reduce(1, *)
        for lane in 0..<lanes {
            var from = 0, to = 0, remainder = lane
            if axis > 0 {
                for dimension in stride(from: axis - 1, through: 0, by: -1) {
                    from += (remainder % shape[dimension]) * src[dimension]
                    to += (remainder % shape[dimension]) * dst[dimension]
                    remainder /= shape[dimension]
                }
            }
            for row in 0..<count {
                let fromRow = from + (start + row) * src[axis], toRow = to + (target + row) * dst[axis]
                if src.last == 1, dst.last == 1 {
                    targetData.advanced(by: toRow).update(from: sourceData + fromRow, count: shape.last!)
                } else {
                    for t in 0..<shape.last! { targetData[toRow + t * dst.last!] = sourceData[fromRow + t * src.last!] }
                }
            }
        }
    }

    /// No temporary full-size Swift Array, and no connection to a model's
    /// output allocator. Handles padded Core ML float32/float16 row strides.
    static func ownedCopy(_ source: MLMultiArray) throws -> MLMultiArray {
        guard source.dataType == .float32 || source.dataType == .float16 else { throw NeuralStemError.invalidOutput }
        let result = try MLMultiArray(shape: source.shape, dataType: .float32)
        let shape = source.shape.map(\.intValue), src = source.strides.map(\.intValue), dst = result.strides.map(\.intValue)
        guard let inner = shape.last, inner > 0 else { throw NeuralStemError.invalidOutput }
        let output = result.dataPointer.assumingMemoryBound(to: Float.self)
        for row in 0..<(source.count / inner) {
            var from = 0, to = 0, remaining = row
            if shape.count > 1 {
                for dimension in stride(from: shape.count - 2, through: 0, by: -1) {
                    from += (remaining % shape[dimension]) * src[dimension]
                    to += (remaining % shape[dimension]) * dst[dimension]
                    remaining /= shape[dimension]
                }
            }
            if source.dataType == .float32, src.last == 1, dst.last == 1 {
                output.advanced(by: to).update(from: source.dataPointer.assumingMemoryBound(to: Float.self) + from, count: inner)
            } else {
                for i in 0..<inner {
                    let value: Float
                    if source.dataType == .float32 { value = source.dataPointer.assumingMemoryBound(to: Float.self)[from + i * src.last!] }
                    else { value = Float(Float16(bitPattern: source.dataPointer.assumingMemoryBound(to: UInt16.self)[from + i * src.last!])) }
                    output[to + i * dst.last!] = value
                }
            }
        }
        return result
    }
}
