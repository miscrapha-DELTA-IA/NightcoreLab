import Foundation

@_silgen_name("material_alloc_begin") func beginAllocations()
@_silgen_name("material_alloc_end") func endAllocations() -> UInt64
@_silgen_name("material_consume") func consume(_ pointer: UnsafeRawPointer?)

@inline(never)
func positiveControl(_ count: Int) -> Int {
    let array = Array(repeating: count, count: count)
    array.withUnsafeBytes { consume($0.baseAddress) }
    return array.count
}

// Vary inputs and preserve a checksum; prevent inlining the measured call so
// the optimizer cannot replace the batch with loop-invariant constants.
@inline(never)
func resolveOne(_ material: VisualMaterial, _ audio: AudioFeatures,
                _ rhythm: RhythmFrame, _ time: Double) -> MaterialFrame {
    MaterialResolver.resolve(material, features: audio, rhythm: rhythm, timestamp: time)
}

let count = 100_000
let audio = (0..<257).map { i in
    AudioFeatures(bass: Double(i) / 256, energy: Double(256 - i) / 256)
}
let rhythm = (0..<257).map { i in
    RhythmFrame(beatIndex: i, phase: Double(i % 100) / 100,
                timeSinceBeat: Double(i % 100) / 200, bpm: 120,
                beatStrength: 1, barBeat: i % 4, barPhase: nil,
                confidence: 0.9, downbeatConfidence: 0.8)
}
@inline(never)
func batch(_ material: VisualMaterial, _ count: Int) -> Double {
    var checksum = 0.0
    for i in 0..<count {
        let frame = resolveOne(material, audio[i % audio.count], rhythm[i % rhythm.count], Double(i) / 60)
        checksum += frame.parameters.distortion + frame.parameters.beatPulse + frame.timestamp
    }
    return checksum
}
_ = positiveControl(13)
beginAllocations()
let controlSize = positiveControl(4096)
let controlEvents = endAllocations()
precondition(controlEvents > 0 && controlSize == 4096, "Allocation interposer did not observe the positive control")
var records: [[String: Any]] = []
for material in VisualMaterialCatalog.all {
    _ = batch(material, 10_000) // warm Swift/stdlib lazy initialization
    var durations: [Double] = []
    var checksums = 0.0
    // Time with counting disabled: avoid atomic instrumentation overhead.
    for _ in 0..<7 {
        let start = DispatchTime.now().uptimeNanoseconds
        checksums += batch(material, count)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        durations.append(Double(elapsed) / Double(count))
    }
    beginAllocations()
    checksums += batch(material, count)
    let allocations = endAllocations()
    precondition(checksums.isFinite && checksums > 0)
    records.append([
        "material": material.id, "frames": count,
        "median_nanoseconds_per_frame": durations.sorted()[3],
        "min_nanoseconds_per_frame": durations.min()!,
        "max_nanoseconds_per_frame": durations.max()!,
        "observed_allocation_calls": allocations,
        "allocation_calls_per_frame": Double(allocations) / Double(count),
        "checksum": checksums
    ])
}
let report: [String: Any] = [
    "environment": ProcessInfo.processInfo.operatingSystemVersionString,
    "processors": ProcessInfo.processInfo.processorCount,
    "method": "Release -O; 7 timed batches; separate allocation-count batch; warmed inputs; no renderer",
    "allocation_scope": "Observed malloc/calloc/realloc/valloc/posix_memalign and malloc_zone entry points; nested calls deduplicated. Not GPU/VM or whole-app allocations.",
    "positive_control_events": controlEvents,
    "material_frame_stride": MemoryLayout<MaterialFrame>.stride,
    "visual_parameter_set_stride": MemoryLayout<VisualParameterSet>.stride,
    "records": records
]
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
