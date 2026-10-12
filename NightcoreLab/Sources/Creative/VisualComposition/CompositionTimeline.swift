import Foundation

/// A timestamp carries both the presentation clock and the original audio clock.
struct CompositionTimestamp: Codable, Equatable, Sendable {
    let elapsed: TimeInterval
    let sourceTime: TimeInterval
}

/// Immutable mapping between video elapsed time and source-audio time.
/// Matches StoryVideoRequest.sourceTime(at:) without changing that export path.
struct CompositionTimeline: Codable, Equatable, Sendable {
    let sourceStart: TimeInterval
    let playbackSpeed: Double
    let duration: TimeInterval

    enum TimelineError: Error { case invalidTimeMapping }

    init(sourceStart: TimeInterval, playbackSpeed: Double, duration: TimeInterval) throws {
        guard sourceStart.isFinite, sourceStart >= 0,
              playbackSpeed.isFinite, (0.1...4).contains(playbackSpeed),
              duration.isFinite, duration > 0, duration <= 86_400,
              (sourceStart + duration * playbackSpeed).isFinite else {
            throw TimelineError.invalidTimeMapping
        }
        self.sourceStart = sourceStart
        self.playbackSpeed = playbackSpeed
        self.duration = duration
    }

    func timestamp(at elapsed: TimeInterval) -> CompositionTimestamp? {
        guard elapsed.isFinite, elapsed >= 0, elapsed <= duration else { return nil }
        return CompositionTimestamp(
            elapsed: elapsed, sourceTime: sourceStart + elapsed * playbackSpeed)
    }

    private enum CodingKeys: String, CodingKey {
        case sourceStart, playbackSpeed, duration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(sourceStart: c.decode(Double.self, forKey: .sourceStart),
                          playbackSpeed: c.decode(Double.self, forKey: .playbackSpeed),
                          duration: c.decode(Double.self, forKey: .duration))
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Invalid timeline mapping"))
        }
    }
}
