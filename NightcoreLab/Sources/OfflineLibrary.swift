import Combine
import Foundation

struct OfflineReadiness: Equatable {
    let audio: Bool
    let syncedLyrics: Bool
    let songDNA: Bool
    var isReady: Bool { audio && syncedLyrics && songDNA }
}

enum OfflinePreparation {
    @MainActor
    static func run(audio: () async throws -> URL,
                    syncedLyrics: () async -> Bool,
                    songDNA: (URL) async throws -> Bool) async throws -> OfflineReadiness {
        let url = try await audio()
        try Task.checkCancellation()
        let lyrics = await syncedLyrics()
        try Task.checkCancellation()
        let analysis = try await songDNA(url)
        return OfflineReadiness(audio: true, syncedLyrics: lyrics, songDNA: analysis)
    }
}

/// Coordinates the three existing caches without selecting a new playback source.
@MainActor
final class OfflineLibrary: ObservableObject {
    @Published private(set) var readyIDs = Set<String>()
    @Published private(set) var lyricsReadyIDs = Set<String>()
    @Published private(set) var savingIDs = Set<String>()
    @Published private(set) var failedIDs = Set<String>()
    @Published private(set) var phases: [String: String] = [:]

    private let analysisCache = MusicAnalysisCache()
    private var savingTasks: [String: Task<Void, Never>] = [:]

    func cancel(_ track: Track, downloader: AudioDownloadManager) {
        savingTasks.removeValue(forKey: track.id)?.cancel()
        downloader.cancelOfflineAudio(track)
        savingIDs.remove(track.id)
        phases[track.id] = nil
    }

    func refresh(_ tracks: [Track], downloader: AudioDownloadManager,
                 lyrics: LyricsPrefetcher) {
        Task {
            var ready = Set<String>()
            var synced = Set<String>()
            for track in tracks {
                guard !Task.isCancelled else { return }
                let choice = await lyrics.cachedChoice(for: track.id)
                let hasLyrics = choice?.selected?.syncedLyrics?.isEmpty == false
                if hasLyrics { synced.insert(track.id) }
                let url = downloader.cachedAudioURL(for: track)
                var hasDNA = false
                if let url { hasDNA = await analysisCache.hasOfflineSongDNA(for: url) }
                if OfflineReadiness(audio: url != nil, syncedLyrics: hasLyrics,
                                    songDNA: hasDNA).isReady {
                    ready.insert(track.id)
                }
            }
            readyIDs = ready
            lyricsReadyIDs = synced
        }
    }

    func save(_ track: Track, downloader: AudioDownloadManager,
              lyrics: LyricsPrefetcher) {
        guard savingIDs.insert(track.id).inserted else { return }
        failedIDs.remove(track.id)
        phases[track.id] = "Baixando áudio"
        savingTasks[track.id] = Task {
            do {
                let meta = TrackMetadata(videoID: track.id, rawTitle: track.title,
                    channel: nil, cleanArtist: track.cleanArtist,
                    cleanTitle: track.cleanTitle, album: track.album,
                    duration: track.duration)
                let readiness = try await OfflinePreparation.run(
                    audio: { try await downloader.saveOfflineAudio(track) },
                    syncedLyrics: {
                        self.phases[track.id] = "Salvando letra"
                        return await lyrics.ensureSyncedLyrics(meta)
                    },
                    songDNA: { url in
                        self.phases[track.id] = "Analisando música"
                        let result = try await MusicIntelligenceEngine.shared.analysis(for: url)
                        return result.energyTimeline != nil && result.isTerminal
                    })
                try Task.checkCancellation()
                if readiness.syncedLyrics { lyricsReadyIDs.insert(track.id) }
                if readiness.isReady {
                    readyIDs.insert(track.id)
                } else {
                    failedIDs.insert(track.id)
                }
            } catch {
                if !Task.isCancelled { failedIDs.insert(track.id) }
            }
            phases[track.id] = nil
            savingIDs.remove(track.id)
            savingTasks[track.id] = nil
        }
    }

    func saveMix(_ tracks: [Track], downloader: AudioDownloadManager,
                 lyrics: LyricsPrefetcher) {
        for track in tracks where !readyIDs.contains(track.id) {
            save(track, downloader: downloader, lyrics: lyrics)
        }
    }
}
