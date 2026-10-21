import Darwin
import Foundation

/// Runs only on the serial utility worker, after an inference's autorelease
/// pool has drained. Returns free allocator pages to iOS before retry/admission
/// or handing completion back to the UI. Never called on an audio callback.
enum StemMemoryRecovery {
    static func releaseUnusedPages() {
        malloc_zone_pressure_relief(nil, 0)
    }

    /// Retry only the uncommitted segment. Previously written audio and the
    /// overlap-add accumulator stay intact. Cancellation and corrupt models
    /// must never be retried as if they were memory pressure.
    static func perform<T>(maxRecoveries: Int = 2,
                           recover: (Int) throws -> Void,
                           operation: () throws -> T) throws -> T {
        var recoveries = 0
        while true {
            do { return try operation() }
            catch {
                guard recoveries < maxRecoveries, isMemoryPressure(error) else { throw error }
                recoveries += 1
                try recover(recoveries)
            }
        }
    }

    static func isMemoryPressure(_ error: Error) -> Bool {
        guard let error = error as? NeuralStemError else { return false }
        switch error {
        case .insufficientMemory, .memoryBudget: return true
        default: return false
        }
    }
}
