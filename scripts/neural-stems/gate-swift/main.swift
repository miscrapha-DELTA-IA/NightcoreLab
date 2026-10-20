import CoreML
import Foundation
import GnarlyNeuralDSP

func floats(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    guard data.count % 4 == 0 else { fatalError("Malformed golden tensor") }
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let modelURL = root.appendingPathComponent("htdemucs_core.mlmodelc")
let input = try floats(root.appendingPathComponent("golden/mix.f32"))
let reference = try floats(root.appendingPathComponent("golden/reference.f32"))
let model = try DemucsCoreMLModel(url: modelURL, cpuOnly: false)
let started = Date()
let actual = try model.separate(input)
guard actual.count == reference.count else { fatalError("Different tensor sizes") }
let size = 2 * StemDSP.segmentSamples
var report: [[String: Any]] = []
var passed = true
for source in 0..<4 {
    var sumX = 0.0, sumY = 0.0, xx = 0.0, yy = 0.0, xy = 0.0, error = 0.0
    for i in 0..<size {
        let x = Double(reference[source * size + i]), y = Double(actual[source * size + i])
        guard y.isFinite else { fatalError("Non-finite neural output") }
        sumX += x; sumY += y; xx += x*x; yy += y*y; xy += x*y; error += (x-y)*(x-y)
    }
    let n = Double(size)
    let correlation = (xy-sumX*sumY/n) / sqrt(max(1e-30,(xx-sumX*sumX/n)*(yy-sumY*sumY/n)))
    let normalizedError = sqrt(error / max(xx, 1e-30))
    let line = "\(DemucsCoreMLModel.sources[source]): corr=\(correlation), NRMSE=\(normalizedError), rms=\(sqrt(xx/n))\n"
    try FileHandle.standardError.write(contentsOf: Data(line.utf8))
    if correlation <= 0.98 || normalizedError >= 0.05 { passed = false }
    report.append(["source":DemucsCoreMLModel.sources[source], "correlation":correlation, "nrmse":normalizedError])
}
let data = try JSONSerialization.data(withJSONObject: ["model":DemucsCoreMLModel.identifier,
    "passed":passed, "seconds":Date().timeIntervalSince(started), "sources":report], options: [.prettyPrinted,.sortedKeys])
try data.write(to: root.appendingPathComponent("neural-parity.json"))
guard passed else {
    try FileHandle.standardError.write(contentsOf: Data("NEURAL PARITY GATE FAILED; do not ship\n".utf8))
    exit(1)
}
print("NEURAL PARITY GATE PASSED")
