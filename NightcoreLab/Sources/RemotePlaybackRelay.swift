import Foundation

/// A lightweight, UI-owned bridge for iOS remote commands. AudioEngineManager
/// keeps only a weak reference, so the relay's action handler may capture a
/// SwiftUI ContentView without creating a manager → view retain cycle.
/// No alternate audio engine, queue or playback state is created here.
enum RemotePlaybackAction: Equatable {
    case play
    case pause
    case toggle
    case next
    case previous
    case seek(TimeInterval)
}

@MainActor
final class RemotePlaybackRelay {
    private var handler: ((RemotePlaybackAction) -> Bool)?

    func connect(_ handler: @escaping (RemotePlaybackAction) -> Bool) {
        self.handler = handler
    }

    @discardableResult
    func dispatch(_ action: RemotePlaybackAction) -> Bool {
        handler?(action) ?? false
    }

    func disconnect() {
        handler = nil
    }
}

/// Pure decision rule, separate from AVAudioSession notifications and hardware.
/// An interruption resumes only when iOS opts in, playback was active when
/// interrupted, and the same local source remains loaded.
struct AudioInterruptionResumePolicy {
    static func shouldResume(wasPlaying: Bool, systemAllows: Bool,
                             sameSource: Bool, userOverrode: Bool) -> Bool {
        wasPlaying && systemAllows && sameSource && !userOverrode
    }
}
