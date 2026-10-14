import Foundation
import Combine

/// Coordinates user intent with the authoritative AVAudioEngine transport.
/// AudioEngineManager remains the only source of truth for actual audio playback;
/// PlaybackQueue and PlaybackNavigationHistory remain the authoritative stores.
/// Architectural inspiration: Spotifast player/backend command reconciliation.
/// No Rust or third-party implementation code has been copied.
@MainActor
final class PlaybackCoordinator: ObservableObject {
    /// Legacy transition API retained for existing clients and tests.
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case playing(String)
        case failed(String)
    }

    /// Confirmed state, never inferred from a button tap alone.
    enum TransportState: Equatable {
        case idle
        case loading(String)
        case playing(String?)
        case paused(String?)
        case seeking(String?)
        case ended(String?)
        case failed(String)
    }

    enum RequestedCommand: Equatable {
        case select(String)
        case play
        case pause
        case seek(TimeInterval)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transportState: TransportState = .idle
    @Published private(set) var requestedCommand: RequestedCommand?
    private var token = UUID()

    @discardableResult
    func begin(trackID: String) -> UUID {
        token = UUID()
        phase = .preparing(trackID)
        requestedCommand = .select(trackID)
        transportState = .loading(trackID)
        return token
    }

    func isCurrent(_ request: UUID, trackID: String) -> Bool {
        request == token && phase == .preparing(trackID)
    }

    @discardableResult
    func didStart(_ request: UUID, trackID: String) -> Bool {
        guard isCurrent(request, trackID: trackID) else { return false }
        phase = .playing(trackID)
        requestedCommand = nil
        transportState = .playing(trackID)
        return true
    }

    @discardableResult
    func didFail(_ request: UUID, trackID: String) -> Bool {
        guard isCurrent(request, trackID: trackID) else { return false }
        phase = .failed(trackID)
        requestedCommand = nil
        transportState = .failed(trackID)
        return true
    }

    var isPreparing: Bool {
        if case .preparing = phase { return true }
        return false
    }

    /// Called after AudioEngineManager confirms play/pause. If a selection is
    /// preparing, only didStart/didFail may reconcile its generation token.
    func confirmPlayback(isPlaying: Bool, trackID: String?) {
        guard !isPreparing else { return }
        // At natural EOF, audio.isPlaying becomes false before the queue
        // advances. A secondary SwiftUI onChange must not downgrade ended
        // into paused (or the lock screen would show an ordinary pause).
        if !isPlaying, case .ended(let endedID) = transportState,
           endedID == trackID { return }
        requestedCommand = nil
        // Imported local audio has no Track ID; nil denotes that valid state.
        transportState = isPlaying ? .playing(trackID) : .paused(trackID)
    }

    func togglePlayback(audio: AudioEngineManager, trackID: String?) {
        guard !isPreparing else { return }
        if audio.isPlaying {
            pause(audio: audio, trackID: trackID)
        } else {
            resume(audio: audio, trackID: trackID)
        }
    }

    func resume(audio: AudioEngineManager, trackID: String?) {
        guard !isPreparing, audio.fileName != nil else { return }
        requestedCommand = .play
        audio.play()
        confirmPlayback(isPlaying: audio.isPlaying, trackID: trackID)
    }

    func pause(audio: AudioEngineManager, trackID: String?) {
        guard !isPreparing, audio.fileName != nil else { return }
        requestedCommand = .pause
        audio.pause()
        confirmPlayback(isPlaying: audio.isPlaying, trackID: trackID)
    }

    func seek(to seconds: TimeInterval, audio: AudioEngineManager,
              trackID: String?) {
        guard !isPreparing, seconds.isFinite, audio.fileName != nil,
              audio.duration > 0 else { return }
        let clamped = min(max(0, seconds), audio.duration)
        requestedCommand = .seek(clamped)
        transportState = .seeking(trackID)
        audio.seek(to: clamped)
        confirmPlayback(isPlaying: audio.isPlaying, trackID: trackID)
    }

    func didEnd(trackID: String) {
        guard !isPreparing else { return }
        requestedCommand = nil
        transportState = .ended(trackID)
    }

    /// These methods are gateways over the existing queue/history/session
    /// stores. They intentionally do not introduce another mutable copy.
    func previousCandidate(navigation: PlaybackNavigationHistory) -> Track? {
        navigation.previousTrack
    }

    func nextCandidate(navigation: PlaybackNavigationHistory,
                       queue: PlaybackQueue) -> Track? {
        navigation.forwardTrack ?? queue.upNextQueue.first
    }

    func commitStarted(_ track: Track, replacing previous: Track?,
                       direction: PlaybackNavigationHistory.Direction,
                       queue: PlaybackQueue,
                       navigation: PlaybackNavigationHistory) {
        navigation.commitStarted(track, replacing: previous, direction: direction)
        if direction == .regular { _ = queue.commitPlaying(track) }
    }

    func enqueue(_ tracks: [Track], excluding currentID: String,
                 queue: PlaybackQueue) {
        queue.append(tracks, excluding: currentID)
    }

    @discardableResult
    func reorderQueue(ids: [String], queue: PlaybackQueue) -> Bool {
        queue.reorder(ids: ids)
    }

    func reorderAfterSkip(anchor: Track,
                          vectors: [String: DiscoveryFeatureVector],
                          recentlyPlayed: Set<String>, queue: PlaybackQueue) {
        queue.reorderAfterSkip(anchor: anchor, vectors: vectors,
                               recentlyPlayed: recentlyPlayed)
    }

    func clearQueue(_ queue: PlaybackQueue) {
        queue.clear()
    }

    func saveSession(_ track: Track, position: TimeInterval) {
        PlaybackSessionStorage.save(track, at: position)
    }

    func restoredSession() -> SavedPlaybackSession? {
        PlaybackSessionStorage.load()
    }

    func clearSession() {
        PlaybackSessionStorage.clear()
    }

    func reset() {
        token = UUID()
        phase = .idle
        transportState = .idle
        requestedCommand = nil
    }
}

/// Old call sites and tests keep compiling during incremental migration.
typealias PlaybackTransitionCoordinator = PlaybackCoordinator
