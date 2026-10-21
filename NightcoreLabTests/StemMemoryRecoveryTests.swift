import XCTest
#if canImport(NightcoreLab)
@testable import NightcoreLab
#else
@testable import GnarlyNeuralDSP
#endif

final class StemMemoryRecoveryTests: XCTestCase {
    func testMemoryRetryDoesNotRetainFailedSegmentResources() throws {
        final class Resource {}
        weak var released: Resource?
        var attempts = 0, recoveries = 0
        let value = try StemMemoryRecovery.perform(recover: { _ in
            XCTAssertNil(released, "Failed inference must unwind before memory recovery")
            recoveries += 1
        }) {
            attempts += 1
            let resource = Resource()
            released = resource
            if attempts < 3 {
                throw NeuralStemError.memoryBudget(requiredMiB: 256, availableMiB: 100)
            }
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(recoveries, 2)
    }

    func testPersistentPressureHasBoundedRetries() {
        var attempts = 0
        XCTAssertThrowsError(try StemMemoryRecovery.perform(recover: { _ in }) {
            attempts += 1
            throw NeuralStemError.insufficientMemory
        } as Void)
        XCTAssertEqual(attempts, 3)
    }

    func testCancellationAndInvalidModelsAreNotRetried() {
        let errors: [Error] = [CancellationError(), NeuralStemError.incompatibleModel]
        for error in errors {
            var recoveries = 0
            XCTAssertThrowsError(try StemMemoryRecovery.perform(recover: { _ in recoveries += 1 }) {
                throw error
            } as Void)
            XCTAssertEqual(recoveries, 0)
        }
    }

    func testSpectralSchedulingPreservesEveryRowAndFullHalo() {
        for frequencies in [128, 512] {
            let tiles = StagedDemucsPipeline.spectralTiles(frequencies: frequencies)
            let reordered = ["edge", "inner"].flatMap { variant in tiles.filter { $0.variant == variant } }
            XCTAssertEqual(reordered.count, tiles.count)
            XCTAssertEqual(Set(reordered.map(\.start)), Set(tiles.map(\.start)))
            XCTAssertEqual(reordered.flatMap { Array($0.start..<$0.end) }.sorted(), Array(0..<frequencies))
            for tile in reordered {
                XCTAssertEqual(tile.lower, max(0, tile.start - 2))
                XCTAssertEqual(tile.upper, min(frequencies, tile.end + 2))
                XCTAssertEqual(tile.upper - tile.lower, tile.variant == "edge" ? 34 : 36)
            }
        }
    }
}
