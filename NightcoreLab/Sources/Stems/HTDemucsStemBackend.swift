import CoreML
import Foundation

/// FP32 conversion by dexxdean/htdemucs-coreml (MIT). Its graph contains the
/// STFT and iSTFT, so host-side spectral transforms would corrupt the input.
actor HTDemucsStemBackend: StemSeparationBackend {
    nonisolated let identifier = "htdemucs-coreml"
    nonisolated let modelVersion = "8b4d481-fp32-10s"
    nonisolated let chunkFrames = 441_000
    nonisolated let overlapFrames = 44_100
    nonisolated let modelDescriptor = StemModelDescriptor(
        repository: "dexxdean/htdemucs-coreml",
        revision: "8b4d48132d579d5aa53fb0569de605c64318a2af",
        packageName: "HTDemucs_CoreML.mlpackage",
        files: [
            .init(path: "Manifest.json", byteCount: 617,
                  sha256: "2f02c634b94f7d97db7590766f6d3e15ba299c519dd40f5e476265fecf82a70c"),
            .init(path: "Data/com.apple.CoreML/model.mlmodel", byteCount: 42_821_996,
                  sha256: "2df5b2241de48f4d9752403073488ab54d50ecb3a731acfa2e3e4ab3aac2f3c4"),
            .init(path: "Data/com.apple.CoreML/weights/weight.bin", byteCount: 378_366_080,
                  sha256: "3b7c1b77a48919f4fa8fe744bdf487f46d6c91e00cae09134c8287d4dfa92d6f")
        ])

    private var model: MLModel?

    func loadModel(at compiledURL: URL) throws {
        let configuration = MLModelConfiguration()
        // This conversion documents ANE instability for its FP32 graph.
        configuration.computeUnits = .cpuAndGPU
        model = try MLModel(contentsOf: compiledURL, configuration: configuration)
    }

    func predict(left: [Float], right: [Float]) throws -> [StemKind: StereoStemChunk] {
        try Task.checkCancellation()
        guard let model, left.count == chunkFrames, right.count == chunkFrames else {
            throw StemSeparationError.invalidAudio
        }
        return try autoreleasepool {
            let input = try MLMultiArray(shape: [1, 2, NSNumber(value: chunkFrames)], dataType: .float32)
            let samples = input.dataPointer.bindMemory(to: Float.self, capacity: input.count)
            left.withUnsafeBufferPointer { source in
                samples.update(from: source.baseAddress!, count: chunkFrames)
            }
            right.withUnsafeBufferPointer { source in
                (samples + chunkFrames).update(from: source.baseAddress!, count: chunkFrames)
            }

            let features = try MLDictionaryFeatureProvider(dictionary: ["audio": input])
            let result = try model.prediction(from: features)
            guard let sources = result.featureValue(for: "sources")?.multiArrayValue,
                  sources.dataType == .float32,
                  sources.shape.map(\.intValue) == [1, 4, 2, chunkFrames] else {
                throw StemSeparationError.invalidModelOutput
            }
            let output = sources.dataPointer.bindMemory(to: Float.self, capacity: sources.count)
            let strides = sources.strides.map(\.intValue)
            var stems: [StemKind: StereoStemChunk] = [:]
            for (index, kind) in StemKind.allCases.enumerated() {
                let base = index * strides[1]
                var l = [Float](repeating: 0, count: chunkFrames)
                var r = [Float](repeating: 0, count: chunkFrames)
                for frame in 0..<chunkFrames {
                    l[frame] = output[base + frame * strides[3]]
                    r[frame] = output[base + strides[2] + frame * strides[3]]
                }
                stems[kind] = .init(left: l, right: r)
            }
            return stems
        }
    }
}
