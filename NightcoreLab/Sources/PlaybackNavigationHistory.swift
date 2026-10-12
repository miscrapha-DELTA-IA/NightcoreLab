import Foundation
import Combine

/// Chronological navigation is separate from the recommendation queue and
/// aggregate listening statistics. State changes only when playback succeeds.
@MainActor
final class PlaybackNavigationHistory: ObservableObject {
    enum Direction: Equatable {
        case regular
        case backward
        case forward
    }

    static let limit = 40

    @Published private(set) var previous: [Track] = []
    @Published private(set) var forward: [Track] = []

    var previousTrack: Track? { previous.last }
    var forwardTrack: Track? { forward.last }

    /// Call only after AudioEngineManager.play() has actually started.
    func commitStarted(_ track: Track, replacing current: Track?,
                       direction: Direction = .regular) {
        guard current?.id != track.id else { return }

        switch direction {
        case .regular:
            if let current {
                Self.append(current, to: &previous)
            }
            forward.removeAll()

        case .backward:
            guard previous.last?.id == track.id else { return }
            previous.removeLast()
            if let current {
                Self.append(current, to: &forward)
            }

        case .forward:
            guard forward.last?.id == track.id else { return }
            forward.removeLast()
            if let current {
                Self.append(current, to: &previous)
            }
        }
    }

    func clear() {
        previous.removeAll()
        forward.removeAll()
    }

    private static func append(_ track: Track, to stack: inout [Track]) {
        // A track can be played multiple times non-consecutively; preserve
        // chronology rather than deduplicating the whole stack.
        stack.append(track)
        if stack.count > Self.limit {
            stack.removeFirst(stack.count - Self.limit)
        }
    }
}
