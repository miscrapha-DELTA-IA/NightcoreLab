import Combine
import Foundation

struct OfflineReadiness: Equatable {
    let audio: Bool
    let syncedLyrics: Bool
    let songDNA: Bool
    var isReady: Bool { audio && syncedLyrics && songDNA }
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
        Task {
            do {
                let url = try await downloader.saveOfflineAudio(track)
                phases[track.id] = "Salvando letra"
                let meta = TrackMetadata(videoID: track.id, rawTitle: track.title,
                    channel: nil, cleanArtist: track.cleanArtist,
                    cleanTitle: track.cleanTitle, album: track.album,
                    duration: track.duration)
                let hasLyrics = await lyrics.ensureSyncedLyrics(meta)
                if hasLyrics { lyricsReadyIDs.insert(track.id) }
                phases[track.id] = "Analisando música"
                let result = try await MusicIntelligenceEngine.shared.analysis(for: url)
                if OfflineReadiness(audio: true, syncedLyrics: hasLyrics,
                    songDNA: result.energyTimeline != nil &&
                        result.rhythmAnalysis != nil).isReady {
                    readyIDs.insert(track.id)
                } else {
                    failedIDs.insert(track.id)
                }
            } catch {
                failedIDs.insert(track.id)
            }
            phases[track.id] = nil
            savingIDs.remove(track.id)
        }
    }

    func saveMix(_ tracks: [Track], downloader: AudioDownloadManager,
                 lyrics: LyricsPrefetcher) {
        for track in tracks where !readyIDs.contains(track.id) {
            save(track, downloader: downloader, lyrics: lyrics)
        }
    }
}
