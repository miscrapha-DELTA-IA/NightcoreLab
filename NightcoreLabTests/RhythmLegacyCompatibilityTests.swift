import Foundation
import XCTest
@testable import NightcoreLab

final class RhythmLegacyCompatibilityTests: XCTestCase {
    func testFoundationJSONWithoutRhythmFieldsRetainsEnergyAndOnsets() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("rhythm-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let asset = AudioAssetDescriptor(
            url: folder.appendingPathComponent("fixture.caf"),
            assetID: "legacy-asset", sourceRevision: "legacy-revision",
            duration: 1, format: .init(sampleRate: 16_000, channelCount: 1, formatID: 1))
        let timeline = AudioFeatureTimeline(points: [
            AudioFeaturePoint(time: 0.1, features: AudioFeatures(energy: 0.5))
        ], duration: 1)
        let original = MusicAnalysisResult(asset: asset,
            energy: .available, onsets: .available,
            timeline: timeline, onsetEvents: [0.1])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "rhythmAnalyzerVersion")
        json.removeValue(forKey: "rhythmAnalysis")
        if var statuses = json["capabilities"] as? [String: Any] {
            statuses.removeValue(forKey: "rhythm")
            json["capabilities"] = statuses
        } else if var statuses = json["capabilities"] as? [Any] {
            for index in stride(from: 0, to: statuses.count, by: 2) {
                if statuses[index] as? String == "rhythm" {
                    statuses.removeSubrange(index..<(index + 2))
                    break
                }
            }
            json["capabilities"] = statuses
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(MusicAnalysisResult.self, from: data)
        XCTAssertTrue(decoded.isValid(for: asset))
        XCTAssertEqual(decoded.capabilities[.rhythm], .notRequested)
        XCTAssertEqual(decoded.energyTimeline, original.energyTimeline)
        XCTAssertEqual(decoded.onsetEvents, original.onsetEvents)

        let cacheFolder = folder.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        let filename = AudioAssetDescriptor.digest(Data(asset.assetID.utf8)) + ".json"
        try data.write(to: cacheFolder.appendingPathComponent(filename))
        let loaded = await MusicAnalysisCache(directory: cacheFolder).load(for: asset)
        let recovered = try XCTUnwrap(loaded)
        XCTAssertEqual(recovered.capabilities[.energy], .available)
        XCTAssertEqual(recovered.capabilities[.onsets], .available)
        XCTAssertEqual(recovered.capabilities[.rhythm], .notRequested)
        XCTAssertEqual(recovered.rhythmAnalyzerVersion, RhythmAnalysisResult.algorithmVersion)
    }
}
