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
    }
    struct Manifest: Decodable {
        let modelId: String
        let sources: [String]
        let segmentSamples: Int
        let attentionQueryBlock: Int
        let stageHeadroomBytes: Int
        let stages: [Instruction]
    }
    let manifest: Manifest
    private let root: URL

    init(root: URL) throws {
        self.root = root
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("pipeline.json")))
        guard manifest.modelId == DemucsCoreMLModel.identifier,
              manifest.sources == DemucsCoreMLModel.sources,
              manifest.segmentSamples == StemDSP.segmentSamples,
              manifest.attentionQueryBlock == BlockedAttention.blockRows,
              manifest.stages.count == 25 else { throw NeuralStemError.incompatibleModel }
        for stage in manifest.stages {
            guard !stage.name.isEmpty, stage.name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
                  stage.inputs.count == stage.inputShapes.count,
                  stage.outputs.count == stage.outputShapes.count else { throw NeuralStemError.incompatibleModel }
            if stage.kind == "coreml" {
                guard FileManager.default.fileExists(atPath: root.appendingPathComponent(stage.name + ".mlmodelc").path)
                else { throw NeuralStemError.modelMissing }
            } else if stage.kind != "attention" { throw NeuralStemError.incompatibleModel }
        }
    }

    func run(mix: MLMultiArray, spectrum: MLMultiArray, cpuOnly: Bool,
             check: () throws -> Void, admission: (Int) throws -> Void,
             progress: (Double, String) -> Void) throws -> [String: MLMultiArray] {
        var state = ["mix": mix, "spec": spectrum]
        var remaining: [String: Int] = [:]
        for instruction in manifest.stages {
            for input in instruction.inputs { remaining[input, default: 0] += 1 }
        }
        for (index, instruction) in manifest.stages.enumerated() {
            try check()
            try admission(manifest.stageHeadroomBytes)
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
                let configuration = MLModelConfiguration()
                configuration.computeUnits = cpuOnly ? .cpuOnly : .cpuAndGPU
                let model = try MLModel(contentsOf: root.appendingPathComponent(instruction.name + ".mlmodelc"),
                                        configuration: configuration)
                let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
                guard metadata["gnarly.model_id"] == DemucsCoreMLModel.identifier,
                      metadata["gnarly.stage"] == instruction.name else { throw NeuralStemError.incompatibleModel }
                var feed: [String: MLMultiArray] = [:]
                for i in input.indices {
                    let name = "input_\(i)"
                    if let description = model.modelDescription.inputDescriptionsByName[name] {
                        guard description.multiArrayConstraint?.shape.map(\.intValue) == instruction.inputShapes[i]
                        else { throw NeuralStemError.incompatibleModel }
                        feed[name] = input[i]
                    }
                }
                guard feed.count == model.modelDescription.inputDescriptionsByName.count else {
                    throw NeuralStemError.incompatibleModel
                }
                let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: feed))
                try check()
                return try instruction.outputs.indices.map { i in
                    guard let tensor = prediction.featureValue(for: "output_\(i)")?.multiArrayValue,
                          tensor.shape.map(\.intValue) == instruction.outputShapes[i] else {
                        throw NeuralStemError.incompatibleModel
                    }
                    return try Self.ownedCopy(tensor)
                }
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
