import CoreML
import Darwin
import Foundation
import GnarlyNeuralDSP

func floats(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    guard data.count % 4 == 0 else { fatalError("Malformed golden tensor") }
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let modelURL = root.appendingPathComponent("htdemucs_staged")
let input = try floats(root.appendingPathComponent("golden/mix.f32"))
let reference = try floats(root.appendingPathComponent("golden/reference.f32"))
let cpuOnly = CommandLine.arguments.contains("--cpu-only")
func peakMemoryBytes() -> Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int64(usage.ru_maxrss)
}
func physicalFootprint() -> (current: UInt64, peak: Int64) {
    var info = task_vm_info_data_t()
    let capacity = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    var count = mach_msg_type_number_t(capacity)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? (info.phys_footprint, info.ledger_phys_footprint_peak) : (0, 0)
}
let beforeLoad = peakMemoryBytes()
let loadStarted = Date()
let model = try DemucsCoreMLModel(url: modelURL, cpuOnly: cpuOnly)
let loadSeconds = Date().timeIntervalSince(loadStarted)
let afterLoad = peakMemoryBytes()
let started = Date()
var stageMemory: [[String: Any]] = []
let actual = try model.separate(input, progress: { fraction, name in
    let peak = peakMemoryBytes()
    let physical = physicalFootprint()
    stageMemory.append(["stage": name, "fraction": fraction, "peak_memory_bytes": peak,
                        "physical_bytes": physical.current, "physical_peak_bytes": physical.peak])
    try? FileHandle.standardError.write(contentsOf: Data("Stage \(name): peak=\(peak / 1_048_576)MiB, physical=\(physical.current / 1_048_576)MiB, physicalPeak=\(physical.peak / 1_048_576)MiB\n".utf8))
})
if cpuOnly {
    // A second full inference catches retained stage plans/weights and tensor
    // accumulation that a single-segment gate would miss.
    let repeatOutput = try model.separate(input)
    guard zip(actual, repeatOutput).allSatisfy({ abs($0.0 - $0.1) < 0.00001 }) else {
        fatalError("Repeated inference changed the output")
    }
}
guard actual.count == reference.count else { fatalError("Different tensor sizes") }
func compare(_ actual: [Float], reference: [Float], label: String) throws -> (passed: Bool, sources: [[String: Any]]) {
    let size = 2 * StemDSP.segmentSamples
    guard actual.count == reference.count, actual.count == 4 * size else { fatalError("Different tensor sizes") }
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
        let line = "\(label) \(DemucsCoreMLModel.sources[source]): corr=\(correlation), NRMSE=\(normalizedError)\n"
        try FileHandle.standardError.write(contentsOf: Data(line.utf8))
        if correlation <= 0.98 || normalizedError >= 0.05 { passed = false }
        report.append(["source":DemucsCoreMLModel.sources[source], "correlation":correlation, "nrmse":normalizedError])
    }
    return (passed, report)
}
let white = try compare(actual, reference: reference, label: "noise")
var passed = white.passed
let musicalInput = try floats(root.appendingPathComponent("golden/music-mix.f32"))
let musicalReference = try floats(root.appendingPathComponent("golden/music-reference.f32"))
let musical = try compare(model.separate(musicalInput), reference: musicalReference, label: "music")
passed = passed && musical.passed
// Compare every STFT value, including boundary frames, with PyTorch. If the
// final gate fails, also feed the exact PyTorch tensors into Core ML to locate
// the difference independently of the Swift FFT/reconstruction wrapper.
let goldenSpectrum = try floats(root.appendingPathComponent("golden/spec-input.f32"))
var swiftSpectrum: [Float] = []
for channel in 0..<2 {
    let result = StemDSP.stft(Array(input[(channel * StemDSP.segmentSamples)..<((channel + 1) * StemDSP.segmentSamples)]))
    swiftSpectrum.append(contentsOf: result.re)
    swiftSpectrum.append(contentsOf: result.im)
}
let spectralError = zip(goldenSpectrum, swiftSpectrum).map { abs($0.0 - $0.1) }.max() ?? .infinity
if spectralError >= 0.00001 { passed = false }
try FileHandle.standardError.write(contentsOf: Data("Full STFT max error: \(spectralError)\n".utf8))
let peak = peakMemoryBytes()
// The kernel ledger is the footprint charged to the app (dirty/compressed
// memory); RSS also counts clean mmap/model pages. Keep BOTH in the report.
// Apple: https://developer.apple.com/videos/play/wwdc2022/10106/
let physicalPeak = physicalFootprint().peak
if cpuOnly && (physicalPeak <= 0 || physicalPeak > 400 * 1_024 * 1_024 || peak > 800 * 1_024 * 1_024) { passed = false }
try FileHandle.standardError.write(contentsOf: Data("Core ML \(cpuOnly ? "CPU" : "GPU"): load=\(loadSeconds)s, peak=\(peak / 1_048_576)MiB, baseline=\(beforeLoad / 1_048_576)MiB, loaded=\(afterLoad / 1_048_576)MiB\n".utf8))
let data = try JSONSerialization.data(withJSONObject: ["model":DemucsCoreMLModel.identifier,
    "passed":passed, "compute_units":cpuOnly ? "cpuOnly" : "cpuAndGPU",
    "peak_memory_bytes":peak, "physical_peak_bytes":physicalPeak, "memory_metric":"kernel_physical_footprint", "physical_limit_bytes":400 * 1_024 * 1_024, "resident_limit_bytes":800 * 1_024 * 1_024, "before_load_bytes":beforeLoad, "after_load_bytes":afterLoad, "load_seconds":loadSeconds, "seconds":Date().timeIntervalSince(started), "sources":white.sources, "musical_sources":musical.sources,
    "stft_max_error":spectralError, "stage_memory":stageMemory], options: [.prettyPrinted,.sortedKeys])
try data.write(to: root.appendingPathComponent(cpuOnly ? "neural-parity-cpu.json" : "neural-parity.json"))
guard passed else {
    try FileHandle.standardError.write(contentsOf: Data("NEURAL PARITY GATE FAILED; do not ship\n".utf8))
    exit(1)
}
print("NEURAL PARITY GATE PASSED")
