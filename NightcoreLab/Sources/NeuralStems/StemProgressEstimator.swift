import Foundation

/// The first segment includes cold model preparation. Never extrapolate it
/// to the whole song. Use recent, uninterrupted warm segments instead.
struct StemProgressEstimator {
    private var sawFirst = false
    private var samples: [Double] = []

    mutating func record(seconds: Double, recoveredMemory: Bool) {
        defer { sawFirst = true }
        guard sawFirst, !recoveredMemory, seconds.isFinite, seconds > 0 else { return }
        samples.append(seconds)
        if samples.count > 5 { samples.removeFirst() }
    }

    func remainingSeconds(segments: Int) -> Double? {
        guard segments > 0, samples.count >= 2 else { return nil }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        return median * Double(segments)
    }

    func message(segments: Int) -> String {
        guard let seconds = remainingSeconds(segments: segments) else {
            return "Separando · medindo o tempo neste iPhone…"
        }
        let low = max(1, Int(ceil(seconds * 0.8 / 60)))
        let high = max(low, Int(ceil(seconds * 1.2 / 60)))
        return low == high ? "Separando · cerca de \(high) min restantes"
            : "Separando · estimativa de \(low)–\(high) min restantes"
    }
}
