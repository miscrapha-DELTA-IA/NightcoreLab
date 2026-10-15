import SwiftUI
import UIKit
import UniformTypeIdentifiers
import SDWebImageSwiftUI

@MainActor
final class PlaybackQueue: ObservableObject {
    @Published private(set) var upNextQueue: [Track] = []
    var tracks: [Track] { upNextQueue }

    func replace(with candidates: [Track], excluding currentID: String) {
        var seen = Set([currentID])
        upNextQueue = candidates.filter { seen.insert($0.id).inserted }
    }

    /// Stage the selection without mutating the visible queue.
    func remaining(after track: Track) -> [Track]? {
        guard let index = upNextQueue.firstIndex(where: { $0.id == track.id }) else { return nil }
        return Array(upNextQueue.dropFirst(index + 1))
    }

    func contains(_ track: Track) -> Bool {
        upNextQueue.contains(where: { $0.id == track.id })
    }

    @discardableResult
    func remove(_ track: Track) -> Bool {
        guard let index = upNextQueue.firstIndex(where: { $0.id == track.id }) else { return false }
        upNextQueue.remove(at: index)
        return true
    }

    /// Smart Queue: preserve all other items, including items before the one
    /// selected. Never mutate until the playback engine confirms success.
    @discardableResult
    func commitPlaying(_ track: Track) -> Bool {
        guard let index = upNextQueue.firstIndex(where: { $0.id == track.id }) else { return false }
        upNextQueue.remove(at: index)
        return true
    }

    /// Radio never replaces existing music, deduplicates against both the
    /// playing track and everything already enqueued.
    func append(_ candidates: [Track], excluding currentID: String) {
        var seen = Set(upNextQueue.map(\.id))
        seen.insert(currentID)
        let fresh = candidates.filter { seen.insert($0.id).inserted }
        guard !fresh.isEmpty else { return }
        upNextQueue.append(contentsOf: fresh)
    }

    /// Manual reorder must preserve every candidate exactly once.
    /// Invalid/stale reorder requests leave the queue untouched.
    @discardableResult
    func reorder(ids: [String]) -> Bool {
        let existing = Dictionary(uniqueKeysWithValues: upNextQueue.map { ($0.id, $0) })
        guard ids.count == upNextQueue.count,
              Set(ids).count == ids.count,
              Set(ids) == Set(existing.keys) else { return false }
        upNextQueue = ids.compactMap { existing[$0] }
        return true
    }

    /// A committed skip may change priority, but never enqueue or prefetch a new file.
    func reorderAfterSkip(anchor: Track, vectors: [String: DiscoveryFeatureVector],
                          recentlyPlayed: Set<String> = []) {
        upNextQueue = DiscoveryQueuePolicy.afterSkip(upNextQueue, anchor: anchor,
                        vectors: vectors, recentlyPlayed: recentlyPlayed)
    }

    func shouldFetchRadio(afterAutomaticAdvance: Bool) -> Bool {
        afterAutomaticAdvance && upNextQueue.count < 2
    }

    func clear() { upNextQueue.removeAll() }
}

struct ContentView: View {
    @State private var audio = AudioEngineManager()

    @State private var speed: Float = 1.0
    @State private var reverb: Float = 0
    @State private var bass: Float = 0
    @State private var keepOriginalPitch = false
    @State private var isVertical = false
    @State private var isAdjustingSlider = false
    @State private var isDraggingTime = false
    @State private var dragProgress: Double = 0.0

    /// Estilo persistente: Turbulent é o padrão, mas o utilizador pode escolher outro.
    @AppStorage("playerBackgroundStyle") private var bgStyleRaw = PlayerBackgroundStyle.turbulent.rawValue
    @AppStorage("creativeReactionMode")
    private var creativeReactionMode: CreativePreset.AudioReaction = .off
    @AppStorage(CreativePresetCatalog.storageKey)
    private var selectedCreativePresetID = CreativePresetCatalog.defaultID
    @AppStorage(TypographyStyle.storageKey)
    private var karaokeTypographyStyle: TypographyStyle = .neon

    private var bgStyle: PlayerBackgroundStyle {
        PlayerBackgroundStyle(rawValue: bgStyleRaw) ?? .turbulent
    }

    @State private var showImporter = false
    @State private var showPerformanceMode = false
    @State private var exportFormat: ExportFormat = .m4a
    @State private var shareItem: ShareItem?
    @State private var errorMessage: String?

    // Download por link do YouTube (via microserviço)
    @StateObject private var downloader = AudioDownloadManager.shared
    @StateObject private var offlineLibrary = OfflineLibrary()
    @StateObject private var playbackQueue = PlaybackQueue()
    @StateObject private var playbackTransition = PlaybackCoordinator()
    @StateObject private var navigationHistory = PlaybackNavigationHistory()
    @State private var remoteRelay = RemotePlaybackRelay()
    @State private var coverURL: URL?
    @State private var relatedVideos: [Track] = []
    @State private var suggestionReasons: [String: String] = [:]
    @State private var discoveryEvents: [DiscoveryEvent] = []
    @State private var acousticVectors: [String: DiscoveryFeatureVector] = [:]
    @State private var discoveryTracker = DiscoveryPlaybackTracker()
    @State private var discoveryAnalysisTask: Task<Void, Never>?
    @State private var discoveryLog = DiscoveryEventLog()
    /// Serialize event persistence and local deletion despite asynchronous Tasks.
    @State private var discoveryPersistenceTask: Task<Void, Never>?
    @State private var playingTrackID: String?
    @State private var currentTrack: Track?
    @State private var resumeTrack: Track?
    @State private var didRestoreSession = false
    @State private var showLyrics = false
    @State private var lyricsPrefetcher: LyricsPrefetcher?
    @State private var isLoadingRelated = false
    @State private var relatedSourceURL: String?
    @State private var relatedRequestID = UUID()
    @State private var autoplayWhenRadioReady = false
    @State private var showServerSettings = false

    @AppStorage(TelemetryManager.enabledKey) private var telemetryEnabled = false
    @AppStorage("selectedTheme") private var currentTheme: AppTheme = .acid
    // Clean is a presentation preference, not a PanelStore visibility mask.
    @AppStorage("lyricsCleanMode") private var lyricsCleanMode = true
    @AppStorage(KaraokePrefs.background) private var karaokeBackgroundStyle: BackgroundStyle = .marble
    @AppStorage("showDiscover") private var isDiscoverExpanded = true
    @State private var searchDrawer = SearchDrawerState()
    @State private var drawerToast: String?
    @State private var pendingMix: [Track]?
    @State private var karaokeSummary: KaraokeSummary?
    @AppStorage("showAudioWorkspace") private var isAudioWorkspaceExpanded = true
    @AppStorage("showQueue") private var isQueueExpanded = true
    @AppStorage("showExport") private var isExportExpanded = true

    @Environment(LyricsStore.self) private var lyricsStore
    @Environment(PanelStore.self) private var panels
    @Environment(PlayHistoryStore.self) private var playHistory
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.energyBudget) private var energyBudget

    // Troque pelo seu link (Ko-fi, GitHub Sponsors, página com QR Code do Pix…)
    private let donationURL = URL(string: "https://ko-fi.com/SEU_USUARIO")!

    private var hasTrack: Bool { audio.fileName != nil }
    private var hasAudioPanels: Bool {
        PanelID.audioPanels.contains { panels.isVisible($0) }
    }

    /// Migrates the preference from the previous standalone Discover toggle.
    private func restoreDiscoverExpansionPreference() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "showDiscover") == nil,
           let previous = defaults.object(forKey: "isDiscoverExpanded") as? Bool {
            isDiscoverExpanded = previous
        }
    }

    /// Tom resultante: 0 se "Manter o tom original", senão acompanha a velocidade (efeito vinil).
    private var computedPitch: Float {
        keepOriginalPitch ? 0 : 1200 * log2(speed)
    }

    var body: some View { playerPresentations }

    /// O motor permanece nesta View; AnyLayout altera apenas sua apresentação.
    private var playerCanvas: some View {
        NowPlayingScreen(
            track: TrackInfo(track: currentTrack, fileName: audio.fileName, coverURL: coverURL),
            clock: audio.lyricsClock,
            audio: audio,
            isScrollDisabled: isAdjustingSlider,
            isPlaying: audio.isPlaying,
            isTrackLoaded: hasTrack,
            canShowKaraoke: currentTrack != nil,
            hasPreviousTrack: navigationHistory.previousTrack != nil,
            canSkipNext: navigationHistory.forwardTrack != nil ||
                !playbackQueue.upNextQueue.isEmpty,
            appTheme: $currentTheme,
            isKaraokeMode: $showLyrics,
            lyricsCleanMode: $lyricsCleanMode,
            backgroundStyle: $karaokeBackgroundStyle,
            searchDrawer: $searchDrawer,
            karaokeSummary: $karaokeSummary,
            playerBackgroundStyle: bgStyle,
            onPlayPause: { playbackTransition.togglePlayback(audio: audio, trackID: playingTrackID) },
            onPrevious: { goToPreviousTrack() },
            onNext: { goToNextTrack() },
            onReplayKaraoke: { replayKaraoke() },
            header: { header },
            playerDetails: { integratedPlaybackBar },
            searchDrawerContent: { focusRequest in musicWorkspace(focusRequest: focusRequest) },
            normalExtras: { mainScrollContent },
            karaokeContent: {
                if let currentTrack {
                    LyricsView(
                        track: currentTrack,
                        audio: audio,
                        theme: $currentTheme,
                        backgroundStyle: $karaokeBackgroundStyle,
                        lyricsCleanMode: $lyricsCleanMode,
                        dismiss: { withAnimation { showLyrics = false } },
                        inline: true,
                        prefetcher: lyricsPrefetcher,
                        onShowResult: { showKaraokeResult() }
                    )
                    .id(currentTrack.id)
                }
            }
        )
        .tint(currentTheme.accent)
        .preferredColorScheme(.dark)
    }

    private var playerLifecycle: some View {
        playerCanvas
        .onAppear {
            let saved = CreativeSessionPreferences.load()
            currentTheme = saved.theme
            creativeReactionMode = saved.reactionMode
            selectedCreativePresetID = CreativePresetCatalog.liveSelection(saved.experienceID)
            karaokeTypographyStyle = saved.lyricModel
            restoreDiscoverExpansionPreference()
            if lyricsPrefetcher == nil { lyricsPrefetcher = LyricsPrefetcher(store: lyricsStore) }
            restoreLastSession()
            remoteRelay.connect { action in handleRemotePlayback(action) }
            audio.connectRemoteCommands(remoteRelay)
            synchronizeRemoteAvailability()
        }
        .onDisappear {
            audio.connectRemoteCommands(nil)
            remoteRelay.disconnect()
        }
        .onOpenURL { incomingURL in
            guard let components = URLComponents(
                url: incomingURL,
                resolvingAgainstBaseURL: false
            ),
            components.scheme?.lowercased() == "nightcore",
            components.host?.lowercased() == "download",
            components.user == nil,
            components.password == nil,
            components.port == nil else { return }

            var receivedLink = (components.queryItems?.first(where: { $0.name == "link" })?.value ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !receivedLink.contains("://"), let decoded = receivedLink.removingPercentEncoding {
                receivedLink = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !receivedLink.isEmpty else {
                downloader.errorMessage = "O Atalho abriu o app, mas enviou o link vazio. Verifique a URL compartilhada no Atalho ou cole o link nesta caixa."
                return
            }

            downloader.errorMessage = nil
            startDownload(receivedLink)
        }
        .task(id: relatedRequestID) { await loadRelatedVideos() }
        .task { discoveryEvents = await discoveryLog.snapshot() }
        .onChange(of: audio.playbackCompletionCount) { _, _ in
            if showLyrics { showKaraokeResult() }
            if let playingTrackID { playbackTransition.didEnd(trackID: playingTrackID) }
            finishDiscovery(reason: .completed)
            if let currentTrack { playHistory.completePlayback(trackID: currentTrack.id) }
            if karaokeSummary == nil { advanceQueue() }
        }
        .onChange(of: audio.isPlaying) { _, playing in
            playbackTransition.confirmPlayback(isPlaying: playing, trackID: playingTrackID)
            synchronizeRemoteAvailability()
            discoveryTracker.playbackChanged(isPlaying: playing, speed: Double(speed))
            if playing {
                if let currentTrack {
                    playHistory.resumePlaybackIfNeeded(currentTrack, sourceDuration: audio.duration)
                }
                // A manual play/pause is not a request to start radio.
                prefetchUpcoming()
            } else if let currentTrack {
                playbackTransition.saveSession(currentTrack, position: audio.playbackTime)
            }
        }
        // The system's lock-screen controls reflect confirmed queue state.
        .onChange(of: playbackQueue.upNextQueue.map(\.id)) { _, _ in
            synchronizeRemoteAvailability()
        }
        .onChange(of: searchDrawer.isOpen) { _, open in
            if open, let lyricsPrefetcher {
                offlineLibrary.refresh(downloader.allCachedTracks,
                    downloader: downloader, lyrics: lyricsPrefetcher)
            }
        }
        .onChange(of: downloader.cachedIDs) { _, _ in
            if searchDrawer.isOpen, let lyricsPrefetcher {
                offlineLibrary.refresh(downloader.allCachedTracks,
                    downloader: downloader, lyrics: lyricsPrefetcher)
            }
        }
        .onChange(of: navigationHistory.previousTrack?.id) { _, _ in
            synchronizeRemoteAvailability()
        }
        .onChange(of: navigationHistory.forwardTrack?.id) { _, _ in
            synchronizeRemoteAvailability()
        }
        .onChange(of: audio.fileName) { _, _ in
            synchronizeRemoteAvailability()
        }
        .onChange(of: audio.isExporting) { _, _ in
            synchronizeRemoteAvailability()
        }
        // Áudio muda instantaneamente enquanto o dedo arrasta
        .onChange(of: speed) { _, _ in
            discoveryTracker.contextChanged(speed: Double(speed))
            applyPitch()
        }
        .onChange(of: energyBudget.allowsNewAnalysis) { _, isAllowed in
            if !isAllowed {
                discoveryAnalysisTask?.cancel()
                discoveryAnalysisTask = nil
            }
        }
        .onChange(of: keepOriginalPitch) { _, _ in applyPitch() }
        .onChange(of: reverb) { _, value in audio.setReverb(value) }
        .onChange(of: bass)   { _, value in audio.setBass(value) }
        .onChange(of: telemetryEnabled) { _, enabled in
            if !enabled { TelemetryManager.shared.discardPending() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                if let currentTrack {
                    playbackTransition.saveSession(currentTrack, position: audio.playbackTime)
                }
                TelemetryManager.shared.flush()
            }
            if phase == .active { downloader.warmUp() }   // acorda o Render ao voltar para o app
        }
        .task {
            selectedCreativePresetID = CreativePresetCatalog.liveSelection(selectedCreativePresetID)
            downloader.warmUp()
        }
    }

    private var playerPresentations: some View {
        playerLifecycle
        .overlay(alignment: .top) {
            if let drawerToast {
                Label(drawerToast, systemImage: "wifi.exclamationmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 66)
                    .accessibilityIdentifier("searchDrawer.errorToast")
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: drawerToast)
        .sheet(isPresented: $showServerSettings) {
            ServerSettingsView(downloader: downloader, accent: currentTheme.accent)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showPerformanceMode) {
            PerformanceModeView(audio: audio, accent: currentTheme.accent)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff]) { result in
            switch result {
            case .success(let url): importFile(url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
                .presentationDetents([.medium, .large])
        }
        .alert("Ops", isPresented: Binding(get: { errorMessage != nil },
                                           set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Cabeçalho

    private var header: some View {
        HStack(spacing: DS.Spacing.s) {
            VStack(alignment: .leading, spacing: 1) {
                NightcoreBrandLockup(theme: currentTheme)
                Text("v33 · " + currentTheme.displayName.uppercased())
                    .font(.caption2.weight(.heavy))
                    .tracking(2.5)
                    .foregroundStyle(currentTheme.accent)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)

            Spacer(minLength: 0)

            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    headerButton("square.grid.3x3.fill", label: "Abrir Performance Mode") {
                        showPerformanceMode = true
                    }
                    headerButton("heart.fill", label: "Apoiar o projeto") {
                        openURL(donationURL)
                    }

                    // Mostra o ícone do modo para o qual o botão vai trocar
                    headerButton(isVertical ? "slider.horizontal.3" : "slider.vertical.3",
                                 label: isVertical ? "Sliders horizontais" : "Sliders verticais (mesa de som)") {
                        withAnimation(.spring(duration: 0.45, bounce: 0.15)) { isVertical.toggle() }
                    }
                    .sensoryFeedback(.impact(weight: .medium), trigger: isVertical)

                    importButton
                }
            }
        }
    }

    private func headerButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(currentTheme.accent)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 40)
                .glassSurface(Circle(), theme: currentTheme, depth: 0.4)
        }
        .accessibilityLabel(label)
    }

    /// Ação principal: pulsa enquanto não há música carregada, para guiar o primeiro uso.
    private var importButton: some View {
        Button {
            showImporter = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(currentTheme.onAccent)
                .frame(width: 40, height: 40)
                .background(Circle().fill(currentTheme.accent))
                .background {
                    GlowPulse(shape: Circle(), color: currentTheme.accent,
                              isActive: !hasTrack && !downloader.isDownloading, blur: 10)
                }
        }
        .disabled(audio.isExporting || downloader.isDownloading)
        .accessibilityLabel("Importar música MP3, M4A, WAV ou AIFF")
    }

    // Pull the long list out of body, keeping the view hierarchy unchanged.
    private var mainScrollContent: some View {
                VStack(spacing: DS.Spacing.l) {
                    if !hasTrack { musicWorkspace(focusRequest: 0) }
                    resumeSection
                    if downloader.isDownloading {
                        Text(downloadStatusText)
                            .font(DS.Typography.captionNumeric)
                            .foregroundStyle(DS.Ink.secondary)
                            .transition(.opacity)
                    } else if let message = downloader.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Ink.error)
                    }
                    audioWorkspace
                    CollapsibleGlassSection(
                        title: "EXPORTAR", icon: "square.and.arrow.up",
                        isExpanded: $isExportExpanded, tint: currentTheme.accent
                    ) {
                        exportSection
                    }
                    .hideablePanel(.export)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
                .animation(.easeInOut(duration: 0.18), value: downloader.isDownloading)
                .onPreferenceChange(SliderAdjustingKey.self) { isAdjustingSlider = $0 }
    }

    /// Uma superfície única para busca, descoberta e próximas faixas.
    /// Mantém a SearchView montada mesmo recolhida para preservar busca e cache.
    private func musicWorkspace(focusRequest: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                SearchView(
                    downloader: downloader, theme: currentTheme,
                    isEnabled: !audio.isExporting,
                    suggestedTracks: relatedVideos,
                    suggestionReasons: suggestionReasons,
                    isLoadingSuggestions: isLoadingRelated,
                    canRefreshSuggestions: currentTrack != nil,
                    onRefreshSuggestions: { startRadio() },
                    onSelect: { track, _ in selectFromDrawer(track) },
                    onLink: { link in startDownload(link) },
                    onServerSettings: { showServerSettings = true },
                    isDiscoverExpanded: $isDiscoverExpanded,
                    isPresented: !hasTrack || searchDrawer.isOpen,
                    focusRequest: focusRequest,
                    integrated: true,
                    recentTracks: quickLibraryTracks,
                    queuedTracks: playbackQueue.upNextQueue,
                    pendingTrackID: searchDrawer.pendingTrackID,
                    offline: offlineLibrary,
                    onPlayMix: { tracks in playMix(tracks) },
                    onPlayOffline: { tracks in playMix(tracks) },
                    onSaveOffline: { track in saveOffline(track) },
                    onSaveMixOffline: { tracks in
                        guard let lyricsPrefetcher else { return }
                        offlineLibrary.saveMix(tracks, downloader: downloader,
                                               lyrics: lyricsPrefetcher)
                    },
                    onPlayQueue: { track in selectFromDrawer(track) },
                    onRemoveQueue: { track in _ = playbackQueue.remove(track) }
                )
                relatedSection.hideablePanel(.queue)
            }
        }
    }

    private var quickLibraryTracks: [Track] {
        let recent = playHistory.entries.values
            .sorted { $0.lastPlayed > $1.lastPlayed }
            .prefix(8)
            .map { downloader.cachedTrack($0.hit.asTrack) }
        return DrawerQuickAccess.recents(recent: recent,
            cached: downloader.quickLibraryTracks, current: currentTrack)
    }

    private func selectFromDrawer(_ track: Track) {
        guard !audio.isExporting else { return }
        if pendingMix?.first?.id != track.id { pendingMix = nil }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        searchDrawer.beginSelection(trackID: track.id)
        drawerToast = nil
        playTrack(track)
    }

    private func playMix(_ tracks: [Track]) {
        guard tracks.count == 15 || !tracks.isEmpty,
              let first = tracks.first else { return }
        pendingMix = tracks
        selectFromDrawer(first)
    }

    private func saveOffline(_ track: Track) {
        guard let lyricsPrefetcher else { return }
        offlineLibrary.save(track, downloader: downloader, lyrics: lyricsPrefetcher)
    }

    private func finishDrawerSelection(_ trackID: String) {
        guard searchDrawer.pendingTrackID == trackID else { return }
        CreativeHaptics.selection(microphoneActive: audio.karaokeMicrophoneActive)
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            searchDrawer.confirmPlayback(trackID: trackID)
        }
    }

    private func failDrawerSelection(_ trackID: String, message: String) -> Bool {
        guard searchDrawer.selectionFailed(trackID: trackID) else { return false }
        if pendingMix?.first?.id == trackID { pendingMix = nil }
        drawerToast = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if drawerToast == message { drawerToast = nil }
        }
        return true
    }

    private func showKaraokeResult() {
        lyricsStore.scoring.finish()
        guard let currentTrack else { return }
        let info = TrackInfo(track: currentTrack, fileName: audio.fileName,
                             coverURL: coverURL)
        karaokeSummary = KaraokeSummary(track: info,
            snapshot: lyricsStore.scoring.snapshot, mode: lyricsStore.scoring.mode)
    }

    private func replayKaraoke() {
        karaokeSummary = nil
        guard currentTrack != nil else { return }
        lyricsStore.scoring.stop()
        audio.seek(to: 0)
        audio.play()
    }

    /// Presets e controles vivem num único cartão de vidro. O olho ainda
    /// permite ajustar a visibilidade de cada subseção separadamente.
    private var audioWorkspace: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.smooth(duration: 0.32)) {
                    isAudioWorkspaceExpanded.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "dial.high")
                    Text("ÁUDIO")
                        .font(.caption.bold())
                        .tracking(1.3)
                    Spacer()
                    Image(systemName: isAudioWorkspaceExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(currentTheme.accent)
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Área de presets e controles")
            .accessibilityValue(isAudioWorkspaceExpanded ? "Expandida" : "Recolhida")

            if isAudioWorkspaceExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("PRESETS", systemImage: "slider.horizontal.3")
                            .font(.caption.bold())
                            .tracking(1.3)
                            .foregroundStyle(currentTheme.accent)
                        presets
                    }
                    .hideablePanel(.presets)

                    VStack(alignment: .leading, spacing: 10) {
                        Label("CONTROLES", systemImage: "dial.high")
                            .font(.caption.bold())
                            .tracking(1.3)
                            .foregroundStyle(currentTheme.accent)
                        controls
                    }
                    .hideablePanel(.controls)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .frame(height: hasAudioPanels ? nil : 0, alignment: .top)
        .opacity(hasAudioPanels ? 1 : 0)
        .clipped()
        .allowsHitTesting(hasAudioPanels)
        .accessibilityHidden(!hasAudioPanels)
    }

    // Kept outside the main body to avoid SwiftUI's expression type-check explosion.
    @ViewBuilder
    private var resumeSection: some View {
        if let resumeTrack, !hasTrack {
            Button {
                playTrack(resumeTrack)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(currentTheme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ÚLTIMA MÚSICA")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(DS.Ink.secondary)
                        Text(resumeTrack.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("Retomar")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(currentTheme.accent)
                }
                .padding(14)
                .glassSurface(RoundedRectangle(cornerRadius: 16),
                              theme: currentTheme, depth: 0.6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retomar última música: \(resumeTrack.title)")
        }
    }

    private var downloadStatusText: String {
        if downloader.downloadProgress > 0 {
            return "Baixando… \(Int(downloader.downloadProgress * 100))%"
        }
        return downloader.isRetrying
            ? "Servidor acordando, tentando de novo…"
            : "Extraindo o áudio no servidor…"
    }

    // MARK: - Progresso integrado ao cartão do player

    /// Progresso, níveis e estilo de fundo dividem a mesma superfície de
    /// vidro e o mesmo controle de visibilidade do PlayerHeader.
    private var integratedPlaybackBar: some View {
        HStack(spacing: DS.Spacing.m) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("POSIÇÃO")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer(minLength: 4)
                    Text(durationText)
                        .font(DS.Typography.subtitleNumeric)
                        .foregroundStyle(.white)
                }
                miniScrubber
            }
            LevelBars(color: currentTheme.accent, isAnimating: audio.isPlaying)
            bgStyleButton
        }
    }

    /// Linha do tempo minimalista, atualizada sem modificar o pipeline de áudio.
    private var miniScrubber: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 15.0,
                                    paused: !audio.isPlaying || isDraggingTime)) { _ in
                let safeDuration = max(audio.duration, 1)
                let progress = min(max(isDraggingTime ? dragProgress :
                                      audio.playbackTime / safeDuration, 0), 1)
                let width = max(geometry.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.white)
                        .frame(width: width * progress, height: 4)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 12, height: 12)
                        .offset(x: max(0, min(width - 12, width * progress - 6)))
                }
                .frame(height: 12)
                .contentShape(Rectangle())
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard hasTrack, audio.duration > 0 else { return }
                        isDraggingTime = true
                        dragProgress = min(max(Double(value.location.x / max(geometry.size.width, 1)), 0), 1)
                    }
                    .onEnded { value in
                        guard hasTrack, audio.duration > 0 else {
                            isDraggingTime = false
                            return
                        }
                        let percent = min(max(Double(value.location.x / max(geometry.size.width, 1)), 0), 1)
                        playbackTransition.seek(to: percent * audio.duration, audio: audio, trackID: playingTrackID)
                        isDraggingTime = false
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
            )
        }
        .frame(height: 12)
        .padding(.top, 5)
        .accessibilityLabel("Posição da música")
        .accessibilityValue("\(Int(audio.playbackTime)) de \(Int(audio.duration)) segundos")
    }

    /// Menu explícito: a opção Turbulent não se confunde com a capa que desliza.
    private var bgStyleButton: some View {
        Menu {
            ForEach(PlayerBackgroundStyle.allCases, id: \.rawValue) { style in
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        bgStyleRaw = style.rawValue
                    }
                } label: {
                    Label(style.displayName,
                          systemImage: style == bgStyle ? "checkmark.circle.fill" : style.symbolName)
                }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: bgStyle.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(currentTheme.accent)
                    .frame(width: 36, height: 36)
                    .glassSurface(Circle(), theme: currentTheme, depth: 0.4)

                Text(bgStyle == .turbulent ? "FLUIDO" : "FUNDO")
                    .font(.system(size: 8, weight: .black, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(currentTheme.accent)
            }
            .frame(width: 48)
            .contentShape(Rectangle())
        }
        .sensoryFeedback(.selection, trigger: bgStyleRaw)
        .accessibilityLabel("Escolher estilo do fundo do player")
        .accessibilityValue(bgStyle.displayName)
        .accessibilityHint("Fosco, Nítido, Em movimento ou Turbulent Displacement")
    }

    @ViewBuilder
    private var radioButton: some View {
        if currentTrack != nil {
            Button(action: { startRadio() }) {
                Label("Iniciar Rádio", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(currentTheme.accent)
            }
            .buttonStyle(.plain)
            .disabled(audio.isExporting || isLoadingRelated)
            .accessibilityHint("Busca e acrescenta músicas sem substituir a fila")
        }
    }

    // The Up Next queue is separate from discovery and never loses playback state.
    private var relatedSection: some View {
        CollapsibleGlassSection(
            title: "A SEGUIR", icon: "list.dash",
            isExpanded: $isQueueExpanded,
            tint: currentTheme.accent,
            detail: "\(playbackQueue.upNextQueue.count) na fila",
            integrated: true
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if currentTrack != nil {
                    HStack {
                        Spacer(minLength: 0)
                        radioButton
                    }
                }
            if playbackQueue.upNextQueue.isEmpty {
                Text(hasTrack ? "A fila está vazia. As próximas músicas aparecerão aqui." :
                     "Escolha uma música para começar.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Ink.secondary)
            } else {
                ForEach(Array(playbackQueue.upNextQueue.prefix(3).indices), id: \.self) { index in
                    let track = playbackQueue.upNextQueue[index]
                    let status = downloader.status(for: track)
                    Button {
                        playFromQueue(track)
                    } label: {
                        HStack(spacing: 10) {
                            Text(String(format: "%02d", index + 1))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(currentTheme.accent)
                            WebImage(url: track.thumbnailURL)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 42, height: 42)
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(track.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(status == .none ? "Na fila" : status.shortDescription)
                                    .font(.caption2)
                                    .foregroundStyle(status == .downloaded
                                        ? Color.green.opacity(0.85) : DS.Ink.secondary)
                            }
                            Spacer(minLength: 0)
                            TrackStatusIndicator(status: status, accent: currentTheme.accent)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(audio.isExporting)
                }
            }
            }
        }
    }

    private var durationText: String {
        let seconds = Int(audio.duration / Double(speed))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Presets

    private var presets: some View {
        GlassGroup(spacing: DS.Spacing.s) {
            HStack(spacing: DS.Spacing.s) {
                presetButton("Redefinir", speed: 1.0, reverb: 0, bass: 0)
                presetButton("Lentidão", speed: 0.8, reverb: 35, bass: 0)
                presetButton("Nightcore", speed: 1.25, reverb: 0, bass: 5)
            }
        }
        .disabled(!hasTrack)
        .opacity(hasTrack ? 1 : 0.4)
    }

    private func presetButton(_ title: String, speed s: Float, reverb r: Float, bass b: Float) -> some View {
        let isSelected = hasTrack
            && abs(speed - s) < 0.001 && abs(reverb - r) < 0.01 && abs(bass - b) < 0.01

        return Button {
            withAnimation(.spring(duration: 0.35)) {
                speed = s
                reverb = r
                bass = b
            }
        } label: {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isSelected ? currentTheme.accent : DS.Ink.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .glassSurface(Capsule(), theme: currentTheme, isActive: isSelected, pulses: false,
                              glowIntensity: 0.5, depth: 0.4)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Controles

    private var controls: some View {
        VStack(spacing: DS.Spacing.l) {
            pitchToggle
            sliders
            creativeReactionControl
        }
        .disabled(!hasTrack)
        .opacity(hasTrack ? 1 : 0.4)
    }

    /// Optional, local-source music reactive glow. Off by default.
    private var creativeReactionControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path")
                    .foregroundStyle(currentTheme.accent)
                Text("RITMO VISUAL")
                    .font(.caption.weight(.semibold))
                    .tracking(1)
                Spacer()
            }
            Picker("Ritmo visual", selection: $creativeReactionMode) {
                Text("Desligado").tag(CreativePreset.AudioReaction.off)
                Text("Fluido").tag(CreativePreset.AudioReaction.subtle)
                Text("Reativo").tag(CreativePreset.AudioReaction.responsive)
            }
            .pickerStyle(.segmented)
            HStack {
                Text("PRESET")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                Spacer()
                // One selection (creativePresetID) for recipes and complete
                // experiences; the same id reaches the player, karaoke and Story.
                Picker("Preset visual", selection: $selectedCreativePresetID) {
                    Section("Receitas") {
                        ForEach(CreativePresetCatalog.all) { program in
                            Text(program.preset.name).tag(program.id)
                        }
                    }
                    Section("Experiências") {
                        ForEach(CreativePresetCatalog.selectableExperiences) { experience in
                            Text(experience.name).tag(experience.id)
                        }
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("creative.presetPicker")
                .onChange(of: selectedCreativePresetID) { _, id in
                    let liveID = CreativePresetCatalog.liveSelection(id)
                    if id != liveID { selectedCreativePresetID = liveID; return }
                    karaokeTypographyStyle = CreativePresetCatalog.typographyStyle(
                        afterSelecting: liveID, current: karaokeTypographyStyle)
                }
            }
            if let experience = CreativePresetCatalog.selectedExperience(id: selectedCreativePresetID) {
                Text("\(experience.description) · Letra: \(experience.typographyPreset.style.title)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(DS.Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Experiências aplicam programa visual, efeito de letra e reação da letra ao áudio — iguais no player, na prévia e no vídeo. Tema e fonte continuam os seus. Com o ritmo desligado, só o efeito de letra muda; Pouca Energia e Reduzir Movimento pausam a reação.")
                .font(.caption2)
                .foregroundStyle(DS.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .glassSurface(RoundedRectangle(cornerRadius: DS.Radius.medium),
                      theme: currentTheme, depth: 0.5)
    }

    private var pitchToggle: some View {
        Toggle(isOn: $keepOriginalPitch) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Manter o tom original")
                    .font(DS.Typography.bodyStrong)
                    .foregroundStyle(DS.Ink.primary)
                Text(keepOriginalPitch
                     ? "Só a velocidade muda"
                     : "Tom acompanha a velocidade: \(String(format: "%+.0f", computedPitch)) cents")
                    .font(DS.Typography.captionNumeric)
                    .foregroundStyle(DS.Ink.secondary)
                    .contentTransition(.numericText())
            }
        }
        .tint(currentTheme.accent)
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, 12)
        .glassSurface(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous),
                      theme: currentTheme, depth: 0.6)
        .sensoryFeedback(.impact(weight: .light), trigger: keepOriginalPitch)
    }

    /// Mesmo conjunto de sliders nos dois modos. O AnyLayout troca só o arranjo,
    /// preservando a identidade das views, então a rotação é animada em vez de recriada.
    private var sliders: some View {
        let layout = isVertical
            ? AnyLayout(HStackLayout(alignment: .bottom, spacing: 14))
            : AnyLayout(VStackLayout(spacing: DS.Spacing.l))

        return layout {
            GiantSlider(title: "Velocidade", value: $speed,
                        range: AudioEngineManager.speedRange, defaultValue: 1.0,
                        theme: currentTheme, isVertical: isVertical) { String(format: "%.2f×", $0) }

            GiantSlider(title: "Reverb", value: $reverb,
                        range: AudioEngineManager.reverbRange, defaultValue: 0,
                        theme: currentTheme, isVertical: isVertical) { String(format: "%.0f%%", $0) }

            GiantSlider(title: "Baixo", value: $bass,
                        range: AudioEngineManager.bassRange, defaultValue: 0,
                        theme: currentTheme, isVertical: isVertical) { String(format: "+%.1f dB", $0) }
        }
    }

    // MARK: - Exportar

    private var exportSection: some View {
        VStack(spacing: 14) {
            HStack {
                SectionLabel(text: "Exportar")
                Spacer()
            }

            Picker("Formato", selection: $exportFormat) {
                ForEach(ExportFormat.allCases) { Text($0.rawValue.uppercased()).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(audio.isExporting)

            Text(exportFormat.qualityDescription)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Ink.secondary)

            Text("Entrada: MP3, M4A, WAV e AIFF")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Ink.tertiary)

            Button(action: export) {
                ZStack(alignment: .leading) {
                    GeometryReader { geo in
                        // Escurece a parte já renderizada
                        Capsule()
                            .fill(.black.opacity(0.18))
                            .frame(width: geo.size.width * audio.exportProgress)
                    }
                    Text(audio.isExporting
                         ? "Renderizando… \(Int(audio.exportProgress * 100))%"
                         : "Exportar e compartilhar")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(currentTheme.onAccent)
                        .frame(maxWidth: .infinity)
                        .contentTransition(.numericText())
                }
                .frame(height: 56)
                .background(Capsule().fill(currentTheme.accent))
                .clipShape(Capsule())
                .background {
                    GlowPulse(shape: Capsule(), color: currentTheme.accent, isActive: audio.isExporting)
                }
            }
            .disabled(!hasTrack || audio.isExporting || downloader.isDownloading)
            .opacity(hasTrack ? 1 : 0.35)

            Toggle(isOn: $telemetryEnabled) {
                Text("Enviar estatísticas anônimas de uso")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Ink.secondary)
            }
            .tint(.gray)
            .padding(.top, 4)

            Button("Apagar eventos locais de descoberta", role: .destructive) {
                discoveryEvents.removeAll()
                acousticVectors.removeAll()
                suggestionReasons.removeAll()
                let previous = discoveryPersistenceTask
                let log = discoveryLog
                discoveryPersistenceTask = Task {
                    await previous?.value
                    await log.clear()
                }
            }
            .font(DS.Typography.caption)
            .foregroundStyle(DS.Ink.secondary)
            .accessibilityHint("Apaga o log local de descoberta. Não altera o histórico de reproduções.")
        }
        .padding(.top, 8)
    }

    // MARK: - Ações

    /// Remote playback and on-screen controls use the same queue/navigation
    /// transition and the same AVAudioEngine. No second player is created.
    private func handleRemotePlayback(_ action: RemotePlaybackAction) -> Bool {
        guard !audio.isExporting, !playbackTransition.isPreparing else { return false }
        switch action {
        case .play:
            guard hasTrack else { return false }
            playbackTransition.resume(audio: audio, trackID: playingTrackID)
            return audio.isPlaying
        case .pause:
            guard hasTrack else { return false }
            playbackTransition.pause(audio: audio, trackID: playingTrackID)
            return !audio.isPlaying
        case .toggle:
            guard hasTrack else { return false }
            playbackTransition.togglePlayback(audio: audio, trackID: playingTrackID)
            return true
        case .next:
            guard navigationHistory.forwardTrack != nil ||
                  !playbackQueue.upNextQueue.isEmpty else { return false }
            goToNextTrack()
            return true // Playback is confirmed asynchronously before queue commit.
        case .previous:
            guard hasTrack else { return false }
            goToPreviousTrack()
            return true
        case .seek(let position):
            guard hasTrack, position.isFinite, position >= 0,
                  audio.duration > 0 else { return false }
            playbackTransition.seek(to: position, audio: audio, trackID: playingTrackID)
            return true
        }
    }

    private func synchronizeRemoteAvailability() {
        audio.updateRemoteCommandAvailability(
            canSkipNext: !audio.isExporting &&
                (navigationHistory.forwardTrack != nil ||
                 !playbackQueue.upNextQueue.isEmpty),
            canSkipPrevious: !audio.isExporting && hasTrack)
    }

    private func applyPitch() {
        audio.setPlayback(speed: speed, keepOriginalPitch: keepOriginalPitch)
    }

    /// Ponte rede → DSP: baixa o .m4a e injeta no mesmo motor de áudio que a tela usa.
    private func startDownload(_ link: String) {
        guard !audio.isExporting else { return }
        guard let track = Track.from(url: link.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            downloader.errorMessage = "Cole um link válido de vídeo do YouTube."
            if searchDrawer.isOpen { drawerToast = "Confira o link do vídeo e tente novamente." }
            return
        }
        downloader.errorMessage = nil
        if searchDrawer.isOpen { selectFromDrawer(track) }
        else { playTrack(track) }
    }

    private func playFromQueue(_ track: Track, automatic: Bool = false) {
        guard !audio.isExporting, playbackQueue.contains(track) else { return }
        playTrack(track, automaticAdvance: automatic)
    }

    /// Previous always navigates to the most recently played different
    /// track. With no prior track, fall back to restarting the current one.
    private func goToPreviousTrack() {
        guard !audio.isExporting else { return }
        if let previous = playbackTransition.previousCandidate(navigation: navigationHistory) {
            playTrack(previous, navigation: .backward)
        } else {
            playbackTransition.seek(to: 0, audio: audio, trackID: playingTrackID)
        }
    }

    /// After going back, Next returns to the forward track before resuming
    /// the recommendation queue. Neither history action consumes queue items.
    private func goToNextTrack() {
        guard !audio.isExporting else { return }
        if let forward = navigationHistory.forwardTrack {
            playTrack(forward, navigation: .forward)
        } else if let next = playbackQueue.upNextQueue.first {
            playFromQueue(next)
        }
    }

    /// Playback is deliberately independent from radio discovery and queue
    /// replacement. All queue edits happen after play() really starts.
    private func playTrack(_ track: Track, automaticAdvance: Bool = false,
                           navigation: PlaybackNavigationHistory.Direction = .regular) {
        guard !audio.isExporting else { return }
        if !automaticAdvance {
            autoplayWhenRadioReady = false
        }
        let pendingSkip = playHistory.pendingSkip(position: audio.playbackTime,
            duration: audio.duration,
            automaticAdvance: automaticAdvance || navigation != .regular)
        let resumingPrevious = navigation == .regular && resumeTrack?.id == track.id
        let resumeAt = resumingPrevious ? playbackTransition.restoredSession()?.position : nil
        resumeTrack = nil
        let token = playbackTransition.begin(trackID: track.id)
        downloader.select(track, onReady: { localURL, downloadedCoverURL in
            guard playbackTransition.isCurrent(token, trackID: track.id) else { return }
            do {
                try audio.load(url: localURL)
                if let resumeAt, resumeAt > 0, resumeAt < audio.duration {
                    audio.seek(to: resumeAt)
                }
                applyPitch()
                audio.play()
                guard audio.isPlaying else {
                    if playbackTransition.didFail(token, trackID: track.id) {
                        let message = "Não foi possível iniciar a música. Tente novamente."
                        if !failDrawerSelection(track.id, message: message) { errorMessage = message }
                        if resumingPrevious { resumeTrack = track }
                    }
                    return
                }
                guard playbackTransition.didStart(token, trackID: track.id) else { return }
                let wasMixStart = pendingMix?.first?.id == track.id
                // History changes only after a successful start, never at
                // download selection time. Back/forward leave Up Next intact.
                let priorTrack = currentTrack
                let committedTrack = downloader.cachedTrack(track)
                if priorTrack?.id != committedTrack.id {
                    lyricsStore.beginLoading(trackID: committedTrack.id)
                    karaokeSummary = nil
                }
                playbackTransition.commitStarted(committedTrack, replacing: priorTrack,
                    direction: navigation, queue: playbackQueue, navigation: navigationHistory)
                if wasMixStart, let pendingMix {
                    playbackQueue.replace(with: Array(pendingMix.dropFirst()),
                                          excluding: track.id)
                    self.pendingMix = nil
                }
                coverURL = downloadedCoverURL ?? track.thumbnailURL
                playingTrackID = track.id
                currentTrack = committedTrack
                finishDrawerSelection(track.id)
                if let currentTrack {
                    // End the previous listening interval only after replacement starts.
                    let isManualSkip = !automaticAdvance && navigation == .regular &&
                        priorTrack != nil && priorTrack?.id != currentTrack.id
                    finishDiscovery(reason: isManualSkip ? .manualSelection :
                                    (automaticAdvance ? .completed : .nextButton))
                    discoveryTracker.start(currentTrack.id, duration: audio.duration,
                                           speed: Double(speed))
                    if isManualSkip && !wasMixStart {
                        let recentIDs = playHistory.entries.values.sorted {
                            $0.lastPlayed > $1.lastPlayed
                        }.prefix(10).map { $0.hit.id }
                        playbackTransition.reorderAfterSkip(anchor: currentTrack,
                            vectors: acousticVectors,
                            recentlyPlayed: Set(recentIDs), queue: playbackQueue)
                    }
                    analyzeDiscoveryAudio(track: currentTrack, localURL: localURL)
                    playHistory.beginPlayback(currentTrack, sourceDuration: audio.duration,
                                              replacing: pendingSkip)
                    playbackTransition.saveSession(currentTrack, position: audio.playbackTime)
                    startLyricsPrefetch(for: currentTrack)
                }
                prefetchUpcoming()
                if playbackQueue.shouldFetchRadio(afterAutomaticAdvance: automaticAdvance) {
                    startRadio()
                }
            } catch {
                guard playbackTransition.didFail(token, trackID: track.id) else { return }
                let message = "Não foi possível abrir a música. Verifique o arquivo ou a conexão."
                if !failDrawerSelection(track.id, message: message) {
                    errorMessage = "Não foi possível abrir o áudio: \(error.localizedDescription). A fila foi preservada."
                }
                if resumingPrevious { resumeTrack = track }
            }
        }, onFailure: { message in
            guard playbackTransition.didFail(token, trackID: track.id) else { return }
            if !failDrawerSelection(track.id, message: "Não foi possível carregar a música. Confira a conexão e tente novamente.") {
                errorMessage = message + " A fila foi preservada; toque novamente para tentar."
            }
            if resumingPrevious { resumeTrack = track }
        })
    }

    private func restoreLastSession() {
        guard !didRestoreSession else { return }
        didRestoreSession = true
        guard !hasTrack, !downloader.isDownloading,
              let saved = playbackTransition.restoredSession() else { return }
        guard let local = downloader.cachedAudioURL(for: saved.track) else {
            // No silent server request after a cold launch or cache eviction.
            resumeTrack = saved.track
            return
        }
        do {
            try audio.load(url: local)
            applyPitch()
            if saved.position > 0, saved.position < audio.duration {
                audio.seek(to: saved.position)
            }
            coverURL = saved.track.thumbnailURL
            currentTrack = downloader.cachedTrack(saved.track)
            playingTrackID = saved.track.id
            // AudioEngineManager.load() does not start playback.
        } catch {
            resumeTrack = saved.track
        }
    }

    private func lyricsMetadata(for track: Track, duration: TimeInterval?) -> TrackMetadata {
        TrackMetadata(videoID: track.id, rawTitle: track.title, channel: nil,
                      cleanArtist: track.cleanArtist, cleanTitle: track.cleanTitle,
                      album: track.album, duration: duration)
    }

    /// A letra começa a ser procurada quando o áudio realmente tocou,
    /// não quando o usuário abre o modo karaokê.
    private func startLyricsPrefetch(for track: Track) {
        let service = lyricsPrefetcher ?? LyricsPrefetcher(store: lyricsStore)
        lyricsPrefetcher = service
        let metadata = lyricsMetadata(for: track, duration: audio.duration)
        Task(priority: .userInitiated) { await service.start(metadata) }
    }

    private func prefetchUpcoming() {
        guard audio.isPlaying, let playingTrackID else { return }
        downloader.prefetch(playbackQueue.tracks, playing: playingTrackID)
        if let next = playbackQueue.upNextQueue.first, let lyricsPrefetcher {
            let metadata = lyricsMetadata(for: next, duration: next.duration)
            Task { await lyricsPrefetcher.warm(metadata) }
        }
    }

    private func advanceQueue() {
        guard !audio.isExporting, !playbackTransition.isPreparing else { return }
        if let next = playbackQueue.upNextQueue.first {
            playFromQueue(next, automatic: true)
        } else if currentTrack != nil {
            // Only the engine's completion event can trigger an automatic radio
            // request when there is nothing left to advance to.
            startRadio(autoplayWhenReady: true)
        }
    }

    private func startRadio(autoplayWhenReady: Bool = false) {
        guard let track = currentTrack, !audio.isExporting else { return }
        autoplayWhenRadioReady = autoplayWhenReady
        relatedSourceURL = track.url.absoluteString
        relatedRequestID = UUID()
    }

    private func resetRelatedVideos() {
        relatedSourceURL = nil
        autoplayWhenRadioReady = false
        relatedVideos = []
        isLoadingRelated = false
        relatedRequestID = UUID() // Cancela a consulta anterior vinculada à view.
    }

    @MainActor
    private func loadRelatedVideos() async {
        guard let sourceURL = relatedSourceURL else { return }
        let requestID = relatedRequestID
        isLoadingRelated = true
        let videos = await downloader.fetchRelatedVideos(for: sourceURL)
        guard !Task.isCancelled, requestID == relatedRequestID,
              sourceURL == relatedSourceURL else { return }
        isLoadingRelated = false
        // A fetch started for a different playing track must not rewrite the
        // new song's context or trigger an obsolete autoplay.
        guard let playingTrackID, currentTrack?.url.absoluteString == sourceURL else {
            autoplayWhenRadioReady = false
            return
        }
        let ranked = RecommendationRanker.recommendations(
            mix: videos, history: playHistory.entries, currentID: playingTrackID,
            queued: playbackQueue.tracks, context: RecContext(speed: audio.speed, now: .now),
            discovery: discoverySnapshot)
        relatedVideos = ranked
        let snapshot = discoverySnapshot
        suggestionReasons = Dictionary(uniqueKeysWithValues: ranked.compactMap { track in
            RecommendationRanker.whyAppeared(track, history: playHistory.entries,
                context: RecContext(speed: audio.speed, now: .now),
                discovery: snapshot).map { (track.id, $0) }
        })
        playbackTransition.enqueue(ranked, excluding: playingTrackID, queue: playbackQueue)
        prefetchUpcoming()
        if autoplayWhenRadioReady {
            autoplayWhenRadioReady = false
            // Auto-advance only if the original track is still selected and
            // the player has not been changed by a manual tap in the meantime.
            if let currentTrack, currentTrack.id == playingTrackID,
               !audio.isPlaying, !playbackTransition.isPreparing,
               let next = playbackQueue.upNextQueue.first {
                playFromQueue(next, automatic: true)
            }
        }
    }

    private func importFile(_ url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

        do {
            // Copia para o sandbox para não depender do acesso de segurança depois.
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("nightcore_import_\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var imported = false
            defer { if !imported { try? FileManager.default.removeItem(at: folder) } }
            let destination = folder.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: destination)
            try audio.load(url: destination)
            imported = true
            coverURL = nil
            playingTrackID = nil
            currentTrack = nil
            finishDiscovery(reason: .stopped)
            discoveryAnalysisTask?.cancel()
            playHistory.endSession()
            lyricsStore.clear()
            if let lyricsPrefetcher { Task { await lyricsPrefetcher.cancel() } }
            showLyrics = false
            resumeTrack = nil
            playbackTransition.clearSession()
            playbackTransition.clearQueue(playbackQueue)
            navigationHistory.clear()
            playbackTransition.reset()
            downloader.cancel()
            resetRelatedVideos()
            applyPitch()
        } catch {
            TelemetryManager.shared.log(.importFailed)
            errorMessage = "Não foi possível abrir o arquivo: \(error.localizedDescription)"
        }
    }

    private var discoverySnapshot: DiscoverySnapshot {
        DiscoverySnapshot(events: discoveryEvents, vectors: acousticVectors,
            currentID: playingTrackID ?? "",
            materialID: CreativePresetCatalog.material(selection: selectedCreativePresetID).id,
            presetID: selectedCreativePresetID)
    }

    private var discoveryAudioPreset: String? {
        if abs(speed - 1.25) < 0.001 && abs(reverb) < 0.01 && abs(bass - 5) < 0.01 {
            return "nightcore"
        }
        if abs(speed - 0.8) < 0.001 && abs(reverb - 35) < 0.01 && abs(bass) < 0.01 {
            return "lentidao"
        }
        if abs(speed - 1) < 0.001 && abs(reverb) < 0.01 && abs(bass) < 0.01 {
            return "reset"
        }
        return nil // Manual audio controls are not falsely labeled as a preset.
    }

    private func finishDiscovery(reason: DiscoveryEvent.SkipReason?, exported: Bool = false) {
        let event = discoveryTracker.finish(reason: reason, selectedPreset: selectedCreativePresetID,
            materialID: CreativePresetCatalog.material(selection: selectedCreativePresetID).id,
            experienceID: selectedCreativePresetID, audioPreset: discoveryAudioPreset,
            exported: exported)
        guard let event else { return }
        discoveryEvents.append(event)
        if discoveryEvents.count > DiscoveryEventLog.eventLimit {
            discoveryEvents.removeFirst(discoveryEvents.count - DiscoveryEventLog.eventLimit)
        }
        let previous = discoveryPersistenceTask
        let log = discoveryLog
        discoveryPersistenceTask = Task {
            await previous?.value
            await log.append(event)
        }
    }

    private func analyzeDiscoveryAudio(track: Track, localURL: URL) {
        discoveryAnalysisTask?.cancel()
        guard energyBudget.allowsNewAnalysis, localURL.isFileURL else { return }
        // One cancelable offline analysis for the confirmed local track, never per frame.
        discoveryAnalysisTask = Task(priority: .utility) {
            do {
                let result = try await MusicIntelligenceEngine.shared.analysis(for: localURL)
                guard !Task.isCancelled, playingTrackID == track.id else { return }
                acousticVectors[track.id] = DiscoveryFeatureVector(analysis: result)
                if acousticVectors.count > 200 {
                    let permitted = Set(playHistory.entries.keys).union([track.id])
                    acousticVectors = acousticVectors.filter { permitted.contains($0.key) }
                }
            } catch {
                // Missing local features are nil and never block listening.
            }
        }
    }

    private func export() {
        guard !downloader.isDownloading, !audio.isExporting else { return }
        let format = exportFormat
        Task {
            let start = ContinuousClock.now
            do {
                let url = try await audio.exportAudio(format: format)
                let elapsed = ContinuousClock.now - start
                let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                TelemetryManager.shared.log(.exportCompleted(format: format, renderSeconds: seconds))
                finishDiscovery(reason: nil, exported: true)
                shareItem = ShareItem(url: url)
            } catch {
                TelemetryManager.shared.log(.exportFailed(format: format))
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Cartão de sugestão

private struct RelatedVideoCard: View {
    let video: Track
    let theme: AppTheme
    let isEnabled: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
                WebImage(url: video.thumbnailURL)
                    .resizable()
                    .transition(.fade(duration: 0.2))
                    .scaledToFill()
                .frame(width: 152, height: 120)
                .opacity(0.55)

                LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Spacer()
                        Image(systemName: video.isCached ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(theme.accent)
                            .symbolEffect(.pulse, options: .repeating,
                                          isActive: isEnabled && !reduceMotion)
                            .shadow(color: theme.accent.opacity(0.65), radius: 8)
                    }
                    Spacer(minLength: 0)
                    Text(video.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
            }
            .frame(width: 152, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(theme.accent.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityLabel("\(video.isCached ? "Tocar" : "Baixar e tocar") \(video.title)")
    }
}

// MARK: - Capa de vinil

private struct VinylPlaybackArtwork: View {
    let coverURL: URL?
    let isPlaying: Bool
    let theme: AppTheme

    @Environment(\.energyBudget) private var energyBudget
    @State private var spinDegrees: Double = 0
    @State private var spinStartedAt: Date?

    private var shouldSpin: Bool {
        isPlaying && coverURL != nil && energyBudget.allowsDecorativeMotion
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: energyBudget.visualInterval, paused: !shouldSpin)) { context in
            AsyncImage(url: coverURL) { phase in
                ZStack {
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(Circle())
                            .overlay(Circle().fill(.black).frame(width: 12, height: 12))
                            .rotationEffect(.degrees(angle(at: context.date)))
                    } else {
                        // Sem capa, carregando ou com falha: mantém o botão utilizável.
                        Circle().fill(theme.accent)
                    }

                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(phase.image != nil ? Color.white.opacity(0.8) : theme.onAccent)
                        .shadow(color: .black.opacity(phase.image != nil ? 0.7 : 0),
                                radius: 4)
                }
                .frame(width: 64, height: 64)
            }
        }
        .shadow(color: theme.accent.opacity(isPlaying ? 0.5 : 0.2), radius: 14)
        .accessibilityHidden(true) // O botão pai fornece o rótulo Tocar/Pausar.
        .onAppear {
            if shouldSpin { spinStartedAt = Date() }
        }
        .onChange(of: shouldSpin) { _, spinning in
            let now = Date()
            spinDegrees = angle(at: now).truncatingRemainder(dividingBy: 360)
            spinStartedAt = spinning ? now : nil
        }
        .onDisappear {
            spinDegrees = angle(at: Date()).truncatingRemainder(dividingBy: 360)
            spinStartedAt = nil
        }
    }

    private func angle(at date: Date) -> Double {
        guard let spinStartedAt else { return spinDegrees }
        // Uma volta a cada 3 segundos; a pausa conserva o ângulo atual.
        return spinDegrees + max(0, date.timeIntervalSince(spinStartedAt)) * 120
    }
}

// MARK: - Slider gigante (fader)

/// Sobe do slider até a página: true enquanto algum slider está sendo ajustado.
struct SliderAdjustingKey: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

struct GiantSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let defaultValue: Float
    /// Tema ativo: a barra usa o gradiente acento → secundária do tema.
    let theme: AppTheme
    /// true = fader de mesa de som: a barra cresce de baixo para cima.
    var isVertical: Bool = false
    let format: (Float) -> String

    @State private var isDragging = false
    /// Zera sozinho quando o toque termina OU é cancelado (ex.: a página assumiu a rolagem).
    @GestureState private var isTouching = false
    /// Valor "cru" durante o arrasto; o ímã do valor neutro só afeta o valor exibido.
    @State private var raw: Float = 0
    @State private var lastAlong: CGFloat = 0
    @State private var lock: AxisLock = .undecided
    /// 1 = arrasto normal; menor = ajuste mais fino (dedo mais longe da barra).
    @State private var precision: Float = 1

    private enum AxisLock { case undecided, adjust, scroll }

    private let thickness: CGFloat = 72        // altura (horizontal) ou largura máxima (vertical)
    private let verticalLength: CGFloat = 320  // altura do fader vertical

    private var span: Float { range.upperBound - range.lowerBound }
    private var progress: CGFloat { CGFloat((value - range.lowerBound) / span) }
    private var defaultPosition: CGFloat { CGFloat((defaultValue - range.lowerBound) / span) }
    private var trackShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.track, style: .continuous)
    }

    var body: some View {
        Group {
            if isVertical {
                VStack(spacing: DS.Spacing.s) {
                    SectionLabel(text: title)
                    valueLabel
                    track
                        .frame(maxWidth: thickness)
                        .frame(height: verticalLength)
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    HStack {
                        SectionLabel(text: title)
                        Spacer()
                        valueLabel
                    }
                    track
                        .frame(height: thickness)
                }
            }
        }
        .preference(key: SliderAdjustingKey.self, value: isDragging)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            let step = span / 20
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
        }
    }

    private var valueLabel: some View {
        HStack(spacing: 6) {
            if isDragging, let precisionLabel {
                Text(precisionLabel)
                    .font(DS.Typography.captionNumeric)
                    .foregroundStyle(theme.accent)
            }
            Text(format(value))
                .font(isVertical ? DS.Typography.valueCompact : DS.Typography.value)
                .foregroundStyle(isDragging ? theme.accent : DS.Ink.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
        }
        .animation(.easeOut(duration: 0.15), value: isDragging)
    }

    private var precisionLabel: String? {
        switch precision {
        case ..<0.15: return "⅒×"
        case ..<0.3:  return "¼×"
        case ..<0.9:  return "½×"
        default:      return nil
        }
    }

    // MARK: Gesto

    /// Horizontal: arrasto direto, mas só vira ajuste se o movimento for claramente horizontal;
    /// gesto vertical é rolagem da página e não toca no slider.
    private func adjustHorizontal(_ g: DragGesture.Value, length: CGFloat) {
        if lock == .undecided {
            lock = abs(g.translation.width) > abs(g.translation.height) * 1.3 ? .adjust : .scroll
            if lock == .adjust { beginAdjust() }
        }
        guard lock == .adjust else { return }
        applyDrag(along: g.translation.width, across: g.translation.height, length: length, sign: 1)
    }

    /// Vertical (mesa de som): arrasto na vertical conflita com a rolagem, então o fader
    /// só é "agarrado" após segurar ~0,15 s. Um deslize rápido continua rolando a página.
    private func adjustVertical(_ g: DragGesture.Value?, length: CGFloat) {
        if lock == .undecided {
            lock = .adjust
            beginAdjust()
        }
        guard let g else { return }
        applyDrag(along: g.translation.height, across: g.translation.width, length: length, sign: -1)
    }

    private func beginAdjust() {
        raw = value
        lastAlong = 0
        isDragging = true
    }

    private func endAdjust() {
        lock = .undecided
        precision = 1
        isDragging = false
    }

    /// Ajuste relativo: o valor parte de onde está e só muda pelo quanto o dedo se mexeu.
    /// Afastar o dedo da barra (no eixo transversal) reduz a razão: ½×, ¼×, ⅒×.
    private func applyDrag(along: CGFloat, across: CGFloat, length: CGFloat, sign: Float) {
        guard length > 0 else { return }
        let delta = Float((along - lastAlong) / length)
        lastAlong = along

        let ratio = precisionRatio(forDistance: abs(across))
        if ratio != precision { precision = ratio }

        raw = min(max(raw + sign * delta * span * ratio, range.lowerBound), range.upperBound)
        // Ímã no valor neutro, sem prender: `raw` continua acumulando por baixo.
        value = abs(raw - defaultValue) < span * 0.02 * ratio ? defaultValue : raw
    }

    private func precisionRatio(forDistance distance: CGFloat) -> Float {
        switch distance {
        case ..<48:  return 1
        case ..<110: return 0.5
        case ..<190: return 0.25
        default:     return 0.1
        }
    }

    // MARK: Trilho

    private var track: some View {
        GeometryReader { geo in
            let length = isVertical ? geo.size.height : geo.size.width

            ZStack(alignment: isVertical ? .bottom : .leading) {
                // Sulco rebaixado: borda escura em cima e clara embaixo, como um fader físico
                trackShape
                    .fill(Color.white.opacity(0.045))
                    .overlay(
                        trackShape.strokeBorder(
                            LinearGradient(colors: [.black.opacity(0.55), .white.opacity(0.09)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1
                        )
                    )

                // Preenchimento: cresce da esquerda (horizontal) ou de baixo (vertical)
                trackShape
                    .fill(theme.gradient(vertical: isVertical))
                    .frame(width: isVertical ? nil : length * progress,
                           height: isVertical ? length * progress : nil)
                    .shadow(color: theme.accent.opacity(isDragging ? 0.7 : 0.35),
                            radius: isDragging ? 16 : 9)
                    .overlay(alignment: isVertical ? .top : .trailing) {
                        // Linha de leitura na ponta da barra
                        Capsule()
                            .fill(.white.opacity(0.9))
                            .frame(width: isVertical ? 28 : 3, height: isVertical ? 3 : 28)
                            .padding(isVertical ? .top : .trailing, 10)
                            .opacity(progress > 0.08 ? 1 : 0)
                    }

                // Marcador do valor neutro
                if defaultPosition > 0 && defaultPosition < 1 {
                    Capsule()
                        .fill(.white.opacity(0.35))
                        .frame(width: isVertical ? 28 : 2, height: isVertical ? 2 : 28)
                        .offset(x: isVertical ? 0 : length * defaultPosition - 1,
                                y: isVertical ? -(length * defaultPosition - 1) : 0)
                }
            }
            .contentShape(Rectangle())
            // `simultaneousGesture`: a página continua rolando até o gesto provar que é um ajuste.
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .updating($isTouching) { _, state, _ in state = true }
                    .onChanged { g in
                        guard !isVertical else { return }
                        adjustHorizontal(g, length: length)
                    }
            )
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.15, maximumDistance: 10)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .updating($isTouching) { _, state, _ in state = true }
                    .onChanged { phase in
                        guard isVertical, case .second(true, let g) = phase else { return }
                        adjustVertical(g, length: length)
                    }
            )
            .onChange(of: isTouching) { _, touching in
                if !touching { endAdjust() }
            }
        }
        .scaleEffect(isDragging ? 1.02 : 1)
        .animation(.spring(duration: 0.25), value: isDragging)
        .sensoryFeedback(.selection, trigger: value == defaultValue)
    }
}

// MARK: - Share sheet

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    ContentView()
}
