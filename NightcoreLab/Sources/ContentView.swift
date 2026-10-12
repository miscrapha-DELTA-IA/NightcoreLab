import SwiftUI
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

    func shouldFetchRadio(afterAutomaticAdvance: Bool) -> Bool {
        afterAutomaticAdvance && upNextQueue.count < 2
    }

    func clear() { upNextQueue.removeAll() }
}

@MainActor
final class PlaybackTransitionCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case playing(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    private var token = UUID()

    @discardableResult
    func begin(trackID: String) -> UUID {
        token = UUID()
        phase = .preparing(trackID)
        return token
    }

    func isCurrent(_ request: UUID, trackID: String) -> Bool {
        request == token && phase == .preparing(trackID)
    }

    @discardableResult
    func didStart(_ request: UUID, trackID: String) -> Bool {
        guard isCurrent(request, trackID: trackID) else { return false }
        phase = .playing(trackID)
        return true
    }

    @discardableResult
    func didFail(_ request: UUID, trackID: String) -> Bool {
        guard isCurrent(request, trackID: trackID) else { return false }
        phase = .failed(trackID)
        return true
    }

    var isPreparing: Bool {
        if case .preparing = phase { return true }
        return false
    }

    func reset() {
        token = UUID()
        phase = .idle
    }
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

    private var bgStyle: PlayerBackgroundStyle {
        PlayerBackgroundStyle(rawValue: bgStyleRaw) ?? .turbulent
    }

    @State private var showImporter = false
    @State private var exportFormat: ExportFormat = .m4a
    @State private var shareItem: ShareItem?
    @State private var errorMessage: String?

    // Download por link do YouTube (via microserviço)
    @StateObject private var downloader = AudioDownloadManager.shared
    @StateObject private var playbackQueue = PlaybackQueue()
    @StateObject private var playbackTransition = PlaybackTransitionCoordinator()
    @State private var coverURL: URL?
    @State private var relatedVideos: [Track] = []
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
    @AppStorage("showMusicWorkspace") private var isMusicWorkspaceExpanded = true
    @AppStorage("showAudioWorkspace") private var isAudioWorkspaceExpanded = true
    @AppStorage("showQueue") private var isQueueExpanded = true
    @AppStorage("showExport") private var isExportExpanded = true

    @Environment(LyricsStore.self) private var lyricsStore
    @Environment(PanelStore.self) private var panels
    @Environment(PlayHistoryStore.self) private var playHistory
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    // Troque pelo seu link (Ko-fi, GitHub Sponsors, página com QR Code do Pix…)
    private let donationURL = URL(string: "https://ko-fi.com/SEU_USUARIO")!

    private var hasTrack: Bool { audio.fileName != nil }
    private var hasMusicPanels: Bool {
        PanelID.discoveryPanels.contains { panels.isVisible($0) }
    }
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
            canSkipNext: !playbackQueue.upNextQueue.isEmpty,
            appTheme: $currentTheme,
            isKaraokeMode: $showLyrics,
            lyricsCleanMode: $lyricsCleanMode,
            backgroundStyle: $karaokeBackgroundStyle,
            playerBackgroundStyle: bgStyle,
            onPlayPause: { audio.togglePlayback() },
            onPrevious: { audio.seek(to: 0) },
            onNext: {
                if let next = playbackQueue.upNextQueue.first {
                    playFromQueue(next)
                }
            },
            playerDetails: { integratedPlaybackBar },
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
                        prefetcher: lyricsPrefetcher
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
            restoreDiscoverExpansionPreference()
            if lyricsPrefetcher == nil { lyricsPrefetcher = LyricsPrefetcher(store: lyricsStore) }
            restoreLastSession()
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
        .onChange(of: audio.playbackCompletionCount) { _, _ in
            if let currentTrack { playHistory.completePlayback(trackID: currentTrack.id) }
            advanceQueue()
        }
        .onChange(of: audio.isPlaying) { _, playing in
            if playing {
                if let currentTrack {
                    playHistory.resumePlaybackIfNeeded(currentTrack, sourceDuration: audio.duration)
                }
                // A manual play/pause is not a request to start radio.
                prefetchUpcoming()
            } else if let currentTrack {
                downloader.saveLastTrack(currentTrack, at: audio.playbackTime)
            }
        }
        // Áudio muda instantaneamente enquanto o dedo arrasta
        .onChange(of: speed) { _, _ in
            applyPitch()
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
                    downloader.saveLastTrack(currentTrack, at: audio.playbackTime)
                }
                TelemetryManager.shared.flush()
            }
            if phase == .active { downloader.warmUp() }   // acorda o Render ao voltar para o app
        }
        .task { downloader.warmUp() }
    }

    private var playerPresentations: some View {
        playerLifecycle
        .sheet(isPresented: $showServerSettings) {
            ServerSettingsView(downloader: downloader, accent: currentTheme.accent)
                .presentationDetents([.medium])
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
            AppIconView(theme: currentTheme, showsBackground: false, isPlaying: audio.isPlaying)
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 1) {
                Text("Nightcore Lab")
                    .font(DS.Typography.display)
                    .foregroundStyle(DS.Ink.primary)
                Text(currentTheme.displayName.uppercased())
                    .font(.caption2.weight(.heavy))
                    .tracking(2.5)
                    .foregroundStyle(currentTheme.accent)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)

            Spacer(minLength: 0)

            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
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
                    header.hideablePanel(.header, edge: .top)
                    musicWorkspace
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
    private var musicWorkspace: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.smooth(duration: 0.32)) {
                    isMusicWorkspaceExpanded.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "square.stack.3d.up")
                    Text("MÚSICAS")
                        .font(.caption.bold())
                        .tracking(1.3)
                    Spacer()
                    Image(systemName: isMusicWorkspaceExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(currentTheme.accent)
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Área de busca, descoberta e fila")
            .accessibilityValue(isMusicWorkspaceExpanded ? "Expandida" : "Recolhida")

            VStack(alignment: .leading, spacing: 10) {
                SearchView(
                    downloader: downloader, theme: currentTheme,
                    isEnabled: !audio.isExporting,
                    suggestedTracks: relatedVideos,
                    isLoadingSuggestions: isLoadingRelated,
                    canRefreshSuggestions: currentTrack != nil,
                    onRefreshSuggestions: { startRadio() },
                    onSelect: { track, _ in playTrack(track) },
                    onLink: { link in startDownload(link) },
                    onServerSettings: { showServerSettings = true },
                    isDiscoverExpanded: $isDiscoverExpanded,
                    isPresented: !(hasTrack && currentTrack != nil && showLyrics),
                    integrated: true
                )
                relatedSection.hideablePanel(.queue)
            }
            .frame(height: isMusicWorkspaceExpanded ? nil : 0, alignment: .top)
            .opacity(isMusicWorkspaceExpanded ? 1 : 0)
            .clipped()
            .allowsHitTesting(isMusicWorkspaceExpanded)
            .accessibilityHidden(!isMusicWorkspaceExpanded)
        }
        .padding(14)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
        // Hide the whole workspace without unmounting the omnibox and its state.
        .frame(height: hasMusicPanels ? nil : 0, alignment: .top)
        .opacity(hasMusicPanels ? 1 : 0)
        .clipped()
        .allowsHitTesting(hasMusicPanels)
        .accessibilityHidden(!hasMusicPanels)
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
                        audio.seek(to: percent * audio.duration)
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
        }
        .disabled(!hasTrack)
        .opacity(hasTrack ? 1 : 0.4)
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
        }
        .padding(.top, 8)
    }

    // MARK: - Ações

    private func applyPitch() {
        audio.setPlayback(speed: speed, keepOriginalPitch: keepOriginalPitch)
    }

    /// Ponte rede → DSP: baixa o .m4a e injeta no mesmo motor de áudio que a tela usa.
    private func startDownload(_ link: String) {
        guard !audio.isExporting else { return }
        guard let track = Track.from(url: link.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            downloader.errorMessage = "Cole um link válido de vídeo do YouTube."
            return
        }
        downloader.errorMessage = nil
        playTrack(track)
    }

    private func playFromQueue(_ track: Track, automatic: Bool = false) {
        guard !audio.isExporting, playbackQueue.contains(track) else { return }
        playTrack(track, automaticAdvance: automatic)
    }

    /// Playback is deliberately independent from radio discovery and queue
    /// replacement. All queue edits happen after play() really starts.
    private func playTrack(_ track: Track, automaticAdvance: Bool = false) {
        guard !audio.isExporting else { return }
        if !automaticAdvance {
            autoplayWhenRadioReady = false
        }
        let pendingSkip = playHistory.pendingSkip(position: audio.playbackTime,
            duration: audio.duration, automaticAdvance: automaticAdvance)
        let resumingPrevious = resumeTrack?.id == track.id
        let resumeAt = resumingPrevious ? downloader.loadLastTrack()?.position : nil
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
                        errorMessage = "Não foi possível iniciar a reprodução. A fila foi preservada."
                        if resumingPrevious { resumeTrack = track }
                    }
                    return
                }
                guard playbackTransition.didStart(token, trackID: track.id) else { return }
                // Commit only the selected entry. Search, URLs and queue taps
                // never clear or reorder the remaining queue.
                playbackQueue.commitPlaying(track)
                coverURL = downloadedCoverURL ?? track.thumbnailURL
                playingTrackID = track.id
                currentTrack = downloader.cachedTrack(track)
                if let currentTrack {
                    playHistory.beginPlayback(currentTrack, sourceDuration: audio.duration,
                                              replacing: pendingSkip)
                    downloader.saveLastTrack(currentTrack, at: audio.playbackTime)
                    startLyricsPrefetch(for: currentTrack)
                }
                prefetchUpcoming()
                if playbackQueue.shouldFetchRadio(afterAutomaticAdvance: automaticAdvance) {
                    startRadio()
                }
            } catch {
                guard playbackTransition.didFail(token, trackID: track.id) else { return }
                errorMessage = "Não foi possível abrir o áudio: \(error.localizedDescription). A fila foi preservada."
                if resumingPrevious { resumeTrack = track }
            }
        }, onFailure: { message in
            guard playbackTransition.didFail(token, trackID: track.id) else { return }
            errorMessage = message + " A fila foi preservada; toque novamente para tentar."
            if resumingPrevious { resumeTrack = track }
        })
    }

    private func restoreLastSession() {
        guard !didRestoreSession else { return }
        didRestoreSession = true
        guard !hasTrack, !downloader.isDownloading,
              let saved = downloader.loadLastTrack() else { return }
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
        Task { await service.start(metadata) }
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
            queued: playbackQueue.tracks, context: RecContext(speed: audio.speed, now: .now))
        relatedVideos = ranked
        playbackQueue.append(ranked, excluding: playingTrackID)
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
            playHistory.endSession()
            lyricsStore.clear()
            if let lyricsPrefetcher { Task { await lyricsPrefetcher.cancel() } }
            showLyrics = false
            resumeTrack = nil
            downloader.clearLastTrack()
            playbackQueue.clear()
            playbackTransition.reset()
            downloader.cancel()
            resetRelatedVideos()
            applyPitch()
        } catch {
            TelemetryManager.shared.log(.importFailed)
            errorMessage = "Não foi possível abrir o arquivo: \(error.localizedDescription)"
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinDegrees: Double = 0
    @State private var spinStartedAt: Date?

    private var shouldSpin: Bool {
        isPlaying && coverURL != nil && !reduceMotion
    }

    var body: some View {
        TimelineView(.animation(paused: !shouldSpin)) { context in
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
