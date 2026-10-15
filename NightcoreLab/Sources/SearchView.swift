import SwiftUI
import SDWebImageSwiftUI

/// Presentation-only choice: discovery never merges search hits with recommendations.
enum DiscoveryPresentation {
    static func visibleTracks(searchQuery: String?,
                              searchResults: [Track], suggestions: [Track]) -> [Track] {
        searchQuery == nil ? suggestions : searchResults
    }
}

struct SearchView: View {
    @ObservedObject var downloader: AudioDownloadManager
    let theme: AppTheme
    let isEnabled: Bool
    let suggestedTracks: [Track]
    var suggestionReasons: [String: String] = [:]
    let isLoadingSuggestions: Bool
    let canRefreshSuggestions: Bool
    let onRefreshSuggestions: () -> Void
    let onSelect: (Track, [Track]) -> Void
    let onLink: (String) -> Void
    let onServerSettings: () -> Void
    @Binding var isDiscoverExpanded: Bool
    let isPresented: Bool
    var focusRequest: Int = 0
    var integrated: Bool = false
    var recentTracks: [Track] = []
    var activeTrack: Track? = nil
    var requestedAlbumTrack: Track? = nil
    var requestedAlbumFocus: Int = 0
    var queuedTracks: [Track] = []
    var pendingTrackID: String? = nil
    @ObservedObject var offline: OfflineLibrary
    var onPlayMix: ([Track]) -> Void = { _ in }
    var onPlayOffline: ([Track]) -> Void = { _ in }
    var onSaveOffline: (Track) -> Void = { _ in }
    var onSaveMixOffline: ([Track]) -> Void = { _ in }
    var onPlayQueue: (Track) -> Void = { _ in }
    var onRemoveQueue: (Track) -> Void = { _ in }
    @Environment(PanelStore.self) private var panels
    @Environment(PlayHistoryStore.self) private var playHistory
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchExpansionOverride: Bool?
    @AppStorage("lastSearchQuery") private var lastSearchQuery = ""
    @AppStorage(AudioDownloadManager.serverURLKey) private var savedServerURL = AudioDownloadManager.defaultServerURL
    @State private var omnibox = OmniboxEngine(baseURL: URL(string: AudioDownloadManager.defaultServerURL)!)
    @State private var hasRestoredQuery = false
    @State private var query = ""
    @State private var searchResults: [Track] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var hasSearched = false
    @State private var submittedQuery: String?
    @State private var searchRequestID = UUID()
    @State private var hubTab: DrawerHubTab = .mix
    @State private var collectionAnchor: Track?
    @State private var collectionMode: AlbumArtistMode = .both
    @State private var shuffleSeed = 0
    @FocusState private var isFocused: Bool

    private var typedText: String? {
        if case let .text(text) = OmniboxIntent.classify(query), text.count >= 2 { return text }
        return nil
    }
    private var isSearchMode: Bool { submittedQuery != nil || typedText != nil }
    private var showsQuickAccess: Bool {
        DrawerQuickAccess.shouldShow(query: query, submittedQuery: submittedQuery)
    }
    private var mixTracks: [Track] {
        let base = DrawerSmartMix.resolve(history: Array(playHistory.entries.values),
            cached: downloader.allCachedTracks, discovery: suggestedTracks,
            current: recentTracks.first)
        guard shuffleSeed > 0 else { return base }
        // A stable rotation changes order without fetching or replacing songs.
        return Array(base.enumerated().sorted {
            ($0.offset * 7 + shuffleSeed * 3) % 15 <
                ($1.offset * 7 + shuffleSeed * 3) % 15
        }.map { $0.element })
    }
    private var offlineTracks: [Track] {
        downloader.allCachedTracks.filter { offline.readyIDs.contains($0.id) }
    }
    /// Local library, offline cache, recent history, bundled catalog and search cache.
    private var collectionCandidates: [Track] {
        let history = playHistory.entries.values.sorted { $0.lastPlayed > $1.lastPlayed }
            .map { $0.hit.asTrack }
        return recentTracks + downloader.allCachedTracks + history + queuedTracks +
            suggestedTracks + searchResults + omnibox.results.map(\.asTrack) + mixTracks
    }
    private var collectionResult: AlbumArtistCollection? {
        guard let anchor = collectionAnchor ?? activeTrack ?? recentTracks.first else { return nil }
        return AlbumArtistCollectionResolver.resolve(
            anchor: anchor, candidates: collectionCandidates, mode: collectionMode)
    }
    private func focusAlbumArtist(_ track: Track) {
        collectionAnchor = downloader.cachedTrack(track)
        collectionMode = .both
        hubTab = .albumArtist
        isFocused = false
    }
    private var isDiscoverVisible: Bool {
        PanelPresentation.showsDiscover(hidden: panels.hidden, isZen: panels.isZen,
                                        searchActive: isSearchMode)
    }
    private var discoverExpansion: Binding<Bool> {
        Binding(
            get: { PanelPresentation.discoverExpanded(saved: isDiscoverExpanded,
                       searchActive: isSearchMode, userOverride: searchExpansionOverride) },
            set: { value in
                // Only an explicit accordion tap updates the saved preference.
                isDiscoverExpanded = value
                if isSearchMode { searchExpansionOverride = value }
            }
        )
    }
    private var displayedTracks: [Track] {
        if typedText != nil {
            if !omnibox.results.isEmpty { return omnibox.results.map(\.asTrack) }
            // Só usa o fallback da consulta que o usuário realmente submeteu.
            return submittedQuery == query.trimmingCharacters(in: .whitespacesAndNewlines) ? searchResults : []
        }
        return DiscoveryPresentation.visibleTracks(searchQuery: submittedQuery,
                                            searchResults: searchResults, suggestions: suggestedTracks)
    }

    private func showSuggestions(preserveSavedQuery: Bool = false) {
        searchExpansionOverride = nil
        if !preserveSavedQuery { lastSearchQuery = "" }
        query = ""
        omnibox.queryChanged("")
        searchResults = []
        submittedQuery = nil
        hasSearched = false
        isSearching = false
        errorMessage = nil
        searchRequestID = UUID()
        isFocused = false
    }

    private var looksLikeLink: Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.hasPrefix("http") || text.contains("youtu.be") || text.contains("youtube.com")
    }

    private func handleInput(_ input: String) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, isEnabled else { return }
        isFocused = false
        errorMessage = nil
        searchResults = []
        hasSearched = false
        if case let .direct(videoID) = OmniboxIntent.classify(value) {
            submittedQuery = nil
            searchRequestID = UUID()
            query = ""
            onLink("https://www.youtube.com/watch?v=\(videoID)")
            return
        }
        if value.lowercased().hasPrefix("http") ||
            value.lowercased().contains("youtu.be") ||
            value.lowercased().contains("youtube.com") {
            submittedQuery = nil
            searchRequestID = UUID()
            query = ""
            onLink(value)
        } else {
            // Reveal results for this session without changing either preference.
            searchExpansionOverride = nil
            lastSearchQuery = value
            submittedQuery = value
            searchRequestID = UUID()
        }
    }

    private var quickAccess: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TOCADAS RECENTEMENTE · BIBLIOTECA RÁPIDA")
                .font(.caption2.weight(.heavy)).tracking(0.8)
                .foregroundStyle(theme.accent)
            if recentTracks.isEmpty {
                Text("Suas músicas aparecerão aqui após a primeira reprodução.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 9) {
                        ForEach(recentTracks) { track in
                            VStack(spacing: 4) {
                            Button {
                                isFocused = false
                                onSelect(track, [])
                            } label: {
                                HStack(spacing: 7) {
                                    WebImage(url: track.thumbnailURL)
                                        .resizable().scaledToFill()
                                        .frame(width: 38, height: 38)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    Text(track.title)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: 118, alignment: .leading)
                                    if pendingTrackID == track.id {
                                        ProgressView().tint(theme.accent)
                                    }
                                }
                                .padding(6)
                                .background(.white.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 11))
                            }
                            .buttonStyle(.plain)
                            .disabled(!isEnabled)
                            .accessibilityIdentifier("searchDrawer.recent.\(track.id)")
                            offlineControl(track)
                            Button("💿") { focusAlbumArtist(track) }
                                .font(.caption2)
                                .accessibilityLabel("Álbum e artista de \(track.title)")
                            }
                        }
                    }
                }
            }

            Text("FILA A SEGUIR")
                .font(.caption2.weight(.heavy)).tracking(0.8)
                .foregroundStyle(theme.accent)
            if queuedTracks.isEmpty {
                HStack {
                    Text("A fila está vazia.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if canRefreshSuggestions {
                        Button("Iniciar Rádio", action: onRefreshSuggestions)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.accent)
                    }
                }
            } else {
                ForEach(queuedTracks.prefix(3)) { track in
                    HStack(spacing: 8) {
                        WebImage(url: track.thumbnailURL)
                            .resizable().scaledToFill()
                            .frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        Text(track.title)
                            .font(.caption.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 2)
                        if pendingTrackID == track.id {
                            ProgressView().tint(theme.accent)
                        } else {
                            Button("Tocar Agora") { onPlayQueue(track) }
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(theme.accent)
                                .accessibilityIdentifier("searchDrawer.playQueue.\(track.id)")
                        }
                        offlineControl(track)
                        Button("💿") { focusAlbumArtist(track) }
                            .accessibilityLabel("Álbum e artista de \(track.title)")
                        Button(role: .destructive) { onRemoveQueue(track) } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .disabled(pendingTrackID == track.id)
                        .accessibilityLabel("Remover \(track.title) da fila")
                        .accessibilityIdentifier("searchDrawer.removeQueue.\(track.id)")
                    }
                    .padding(7)
                    .background(.white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(11)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("searchDrawer.quickAccess")
    }

    private var quickHub: some View {
        VStack(alignment: .leading, spacing: 11) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    hubPill(.mix, "⚡ Mix 15")
                    hubPill(.offline, "📥 Offline (\(offlineTracks.count))")
                    hubPill(.queue, "🎵 Fila")
                    hubPill(.albumArtist, "💿 Álbum & Artista")
                }
            }
            .accessibilityIdentifier("searchDrawer.hubTabs")
            switch hubTab {
            case .mix:
                HStack {
                    Button("▶ Tocar Mix (15)") { onPlayMix(mixTracks) }
                        .accessibilityIdentifier("searchDrawer.playMix")
                    Spacer(minLength: 4)
                    Button("🔀 Aleatório") { shuffleSeed += 1 }
                        .accessibilityIdentifier("searchDrawer.shuffleMix")
                }
                .font(.caption.weight(.bold)).foregroundStyle(theme.accent)
                ForEach(mixTracks) { track in hubTrackRow(track) }
            case .offline:
                HStack {
                    Button("▶ Tocar Offline") { onPlayOffline(offlineTracks) }
                        .disabled(offlineTracks.isEmpty)
                    Spacer(minLength: 4)
                    Button("📥 Salvar Mix 15 Offline") { onSaveMixOffline(mixTracks) }
                }
                .font(.caption.weight(.bold)).foregroundStyle(theme.accent)
                if offlineTracks.isEmpty {
                    Text("Nenhuma música completa offline. Salve seu Mix 15 aqui.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(offlineTracks) { track in hubTrackRow(track) }
            case .queue:
                quickAccess
            case .albumArtist:
                albumArtistHub
            }
        }
        .padding(11)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("searchDrawer.quickHub")
    }

    @ViewBuilder
    private var albumArtistHub: some View {
        if let result = collectionResult {
            HStack(spacing: 10) {
                WebImage(url: result.anchor.thumbnailURL)
                    .resizable().scaledToFill().frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.artistName ?? "Artista não identificado")
                        .font(.subheadline.weight(.bold)).lineLimit(1)
                    Text(result.albumTitle ?? "Álbum não informado")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            Picker("Organizar músicas por", selection: $collectionMode) {
                Text("💿 Álbum").tag(AlbumArtistMode.album)
                Text("🎤 Artista").tag(AlbumArtistMode.artist)
                Text("✨ Ambos").tag(AlbumArtistMode.both)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("searchDrawer.albumArtistMode")
            if let notice = result.fallbackNotice {
                Text(notice).font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.white.opacity(0.09), in: Capsule())
                    .accessibilityIdentifier("searchDrawer.albumFallback")
            }
            HStack(spacing: 7) {
                Button("▶ Tocar Tudo") { onPlayMix(result.playbackTracks) }
                    .accessibilityIdentifier("searchDrawer.albumPlayAll")
                Spacer(minLength: 0)
                Button("🔀 Aleatório") { onPlayMix(result.playbackTracks.shuffled()) }
                    .accessibilityIdentifier("searchDrawer.albumShuffle")
                Spacer(minLength: 0)
                Button("📥 Salvar Tudo Offline") {
                    onSaveMixOffline(result.playbackTracks)
                }
                .accessibilityIdentifier("searchDrawer.albumSaveAll")
            }
            .font(.caption2.weight(.bold)).foregroundStyle(theme.accent)
            .disabled(!isEnabled || result.playbackTracks.isEmpty)
            if !result.albumTracks.isEmpty {
                Text("💿 Do Álbum: \(result.albumTitle ?? "Álbum")")
                    .font(.caption.weight(.bold)).foregroundStyle(theme.accent)
                ForEach(result.albumTracks) { track in hubTrackRow(track) }
            }
            if !result.artistTracks.isEmpty {
                Text("🎤 Mais de \(result.artistName ?? "este artista")")
                    .font(.caption.weight(.bold)).foregroundStyle(theme.accent)
                ForEach(result.artistTracks) { track in hubTrackRow(track) }
            }
            if result.playbackTracks.isEmpty {
                Text("Nenhuma faixa encontrada na biblioteca e no cache atual.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("Toque uma música para explorar o álbum ou outras faixas do artista.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func hubPill(_ tab: DrawerHubTab, _ title: String) -> some View {
        Button { hubTab = tab } label: {
            Text(title).font(.caption2.weight(.bold)).lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .fixedSize(horizontal: true, vertical: false)
                .background(hubTab == tab ? theme.accent.opacity(0.23) : .white.opacity(0.07),
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(hubTab == tab ? .isSelected : [])
        .accessibilityIdentifier("searchDrawer.tab.\(tab.rawValue)")
    }

    private func hubTrackRow(_ track: Track) -> some View {
        HStack(spacing: 8) {
            Button { onSelect(track, []) } label: {
                HStack(spacing: 8) {
                    WebImage(url: track.thumbnailURL)
                        .resizable().scaledToFill().frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.cleanTitle ?? track.title)
                            .font(.caption.weight(.semibold)).lineLimit(1)
                        Text(AlbumArtistCollectionResolver.artistName(for: track) ?? "Música")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        if offline.lyricsReadyIDs.contains(track.id) {
                            Text("🎤 Letra").font(.caption2).foregroundStyle(theme.accent)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            Button("💿") { focusAlbumArtist(track) }
                .font(.caption2)
                .buttonStyle(.plain)
                .accessibilityLabel("Álbum e artista de \(track.title)")
                .accessibilityIdentifier("searchDrawer.focusAlbum.\(track.id)")
            offlineControl(track)
        }
        .padding(7)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func offlineControl(_ track: Track) -> some View {
        Group {
            if offline.readyIDs.contains(track.id) {
                Text("✓ Offline").font(.caption2.weight(.bold))
                    .foregroundStyle(.green)
            } else if offline.savingIDs.contains(track.id) {
                ProgressView(value: offlineProgress(for: track))
                    .frame(width: 42)
                    .accessibilityLabel(offline.phases[track.id] ?? "Salvando offline")
            } else {
                Button(offline.failedIDs.contains(track.id) ? "Tentar novamente" : "↓ Offline") {
                    onSaveOffline(track)
                }
                .font(.caption2.weight(.bold)).foregroundStyle(theme.accent)
                .disabled(!isEnabled)
                .accessibilityIdentifier("searchDrawer.saveOffline.\(track.id)")
            }
        }
    }

    private func offlineProgress(for track: Track) -> Double {
        switch offline.phases[track.id] {
        case "Baixando áudio":
            return 0.7 * (downloader.offlineDownloadProgress[track.id] ?? 0)
        case "Salvando letra": return 0.8
        case "Analisando música": return 0.9
        default: return 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button(action: onServerSettings) {
                        Image(systemName: "server.rack").foregroundStyle(theme.accent)
                    }
                    .accessibilityLabel("Configurar servidor")
                    Image(systemName: looksLikeLink ? "arrow.down.circle" : "magnifyingglass")
                        .foregroundStyle(theme.accent)
                    TextField("Buscar música ou colar link", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($isFocused)
                        .onSubmit { handleInput(query) }
                        .disabled(!isEnabled)
                    if isSearching || omnibox.isSearching || downloader.isDownloading {
                        ProgressView().tint(theme.accent)
                    }
                    if !query.isEmpty {
                        Button { showSuggestions() } label: { Image(systemName: "xmark.circle.fill") }
                            .accessibilityLabel("Limpar busca")
                    }
                }
                .padding(14)
                .glassSurface(RoundedRectangle(cornerRadius: 16), theme: theme, depth: 0.6)

                if let pendingTrackID {
                    HStack(spacing: 9) {
                        ProgressView().tint(theme.accent)
                        Text(downloader.isDownloading ? "Preparando música…" : "Iniciando reprodução…")
                            .font(.caption.weight(.semibold))
                        Spacer(minLength: 0)
                        if downloader.isDownloading {
                            Text("\(Int(downloader.downloadProgress * 100))%")
                                .monospacedDigit().font(.caption2)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(theme.accent.opacity(0.14), in: Capsule())
                    .accessibilityIdentifier("searchDrawer.loading.\(pendingTrackID)")
                    if downloader.isDownloading {
                        ProgressView(value: downloader.downloadProgress)
                            .tint(theme.accent)
                    }
                } else if isSearching || omnibox.isSearching {
                    Label("Buscando músicas…", systemImage: "magnifyingglass")
                        .font(.caption).foregroundStyle(theme.accent)
                        .accessibilityIdentifier("searchDrawer.searching")
                }

                if showsQuickAccess || hubTab == .albumArtist {
                    quickHub
                }

                if typedText != nil && omnibox.isShowingStaleCache {
                    Text("Resultados salvos · tentando atualizar")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Resultados em cache; atualização em andamento ou indisponível")
                } else if typedText != nil && omnibox.lastRequestFailed &&
                            omnibox.loadState == .partial {
                    Text("Resultados parciais · um serviço está indisponível")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if typedText != nil && !omnibox.suggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(omnibox.suggestions.prefix(5), id: \.self) { item in
                                Button {
                                    query = item
                                    handleInput(item)
                                } label: {
                                    Text(item)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(.ultraThinMaterial, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

            }
            .hideablePanel(.omnibox, edge: .top)

            if isDiscoverVisible {
                CollapsibleGlassSection(
                    title: "DESCOBRIR",
                    icon: "sparkles",
                    isExpanded: discoverExpansion,
                    tint: theme.accent,
                    integrated: integrated
                ) {
                VStack(alignment: .leading, spacing: 12) {
                    if isSearchMode {
                        Button("Sugestões") { showSuggestions() }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.accent)
                            .accessibilityLabel("Voltar às sugestões")
                    } else if canRefreshSuggestions {
                        Button(action: onRefreshSuggestions) {
                            Label("Iniciar Rádio", systemImage: "dot.radiowaves.left.and.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(theme.accent)
                        }
                        .accessibilityLabel("Iniciar Rádio e acrescentar recomendações à fila")
                    }
                    if let errorMessage, isSearchMode {
                        Text(errorMessage).font(.caption).foregroundStyle(.secondary)
                    } else if isSearchMode && (hasSearched || omnibox.hasSearched) &&
                              displayedTracks.isEmpty && !isSearching && !omnibox.isSearching {
                        Text("Nenhuma música encontrada. Experimente outro termo.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !isSearchMode && suggestedTracks.isEmpty && !isLoadingSuggestions {
                        Text("Escolha uma música para descobrir faixas relacionadas.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if (isSearchMode && (isSearching || omnibox.isSearching)) ||
                       (!isSearchMode && isLoadingSuggestions) {
                        ProgressView(isSearchMode ? "Procurando músicas…" : "Carregando sugestões…")
                            .tint(theme.accent)
                    }
                    if !displayedTracks.isEmpty {
                        Text(isSearchMode ? "Resultados da pesquisa · tocar agora" :
                             "Sugestões relacionadas · tocar agora")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(displayedTracks) { result in
                                    let track = downloader.cachedTrack(result)
                                    let status = downloader.status(for: result)
                                    VStack(alignment: .leading, spacing: 5) {
                                    Button {
                                        isFocused = false
                                        // History counts only after the audio engine confirms playback.
                                        onSelect(track, [])
                                    } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            WebImage(url: track.thumbnailURL)
                                                .resizable()
                                                .transition(.fade(duration: 0.2))
                                                .scaledToFill()
                                                .frame(width: 152, height: 100)
                                                .clipped()
                                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                            Text(track.title)
                                                .font(.caption.weight(.semibold))
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)
                                                .frame(height: 34, alignment: .topLeading)
                                            HStack(spacing: 5) {
                                                if pendingTrackID == track.id {
                                                    ProgressView().tint(theme.accent)
                                                } else {
                                                    TrackStatusIndicator(status: status, accent: theme.accent)
                                                }
                                                Text(pendingTrackID == track.id ? "Preparando…" : status.shortDescription)
                                                    .font(.caption2)
                                                    .foregroundStyle(status == .downloaded
                                                        ? Color.green.opacity(0.85) : theme.accent)
                                            }
                                            if !isSearchMode,
                                               let reason = suggestionReasons[track.id] {
                                                Text("Por que apareceu: " + reason)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(3)
                                                    .accessibilityLabel("Por que apareceu: " + reason)
                                            }
                                        }
                                        .frame(width: 152)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!isEnabled)
                                    HStack(spacing: 8) {
                                        Button("💿") { focusAlbumArtist(track) }
                                            .accessibilityLabel("Álbum e artista de \(track.title)")
                                            .accessibilityIdentifier("searchDrawer.focusAlbum.\(track.id)")
                                        offlineControl(track)
                                    }
                                    }
                                    .frame(width: 152)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.5), value: isDiscoverVisible)
        .onAppear {
            omnibox.useHistoryStore(playHistory)
            if let base = URL(string: AudioDownloadManager.apiBaseURL) { omnibox.useServer(base) }
            guard !hasRestoredQuery else { return }
            hasRestoredQuery = true
            if integrated {
                showSuggestions(preserveSavedQuery: true)
                return
            }
            guard !panels.isHidden(.omnibox) else {
                showSuggestions()
                return
            }
            let previous = lastSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !previous.isEmpty, submittedQuery == nil, searchResults.isEmpty else { return }
            // A deliberate saved text search is restored once, never on every keystroke.
            query = previous
            omnibox.queryChanged(previous)
            submittedQuery = previous
            searchRequestID = UUID()
        }
        .onChange(of: savedServerURL) { _, _ in
            if let base = URL(string: AudioDownloadManager.apiBaseURL) {
                omnibox.useServer(base)
                omnibox.queryChanged(query)
            }
        }
        .onChange(of: panels.isHidden(.omnibox)) { _, hidden in
            if hidden { showSuggestions() }
        }
        .onChange(of: panels.isZen) { _, zen in
            if zen { isFocused = false }
        }
        .onChange(of: isPresented) { _, presented in
            if !presented { showSuggestions(preserveSavedQuery: true) }
            else if showsQuickAccess {
                collectionAnchor = nil
                hubTab = .mix
            }
        }
        .onChange(of: activeTrack?.id) { _, _ in
            collectionAnchor = nil
        }
        .onChange(of: requestedAlbumFocus) { _, _ in
            if let track = requestedAlbumTrack { focusAlbumArtist(track) }
        }
        .onChange(of: focusRequest) { _, _ in
            if isPresented { isFocused = true }
        }
        .onChange(of: query) { _, value in
            searchExpansionOverride = nil
            // Link/ID colado bypassa ambas as APIs de busca.
            if case let .direct(id) = OmniboxIntent.classify(value), isEnabled {
                showSuggestions()
                onLink("https://www.youtube.com/watch?v=\(id)")
                return
            }
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                showSuggestions()
                return
            }
            // Editing invalidates a submitted fallback; never show stale results.
            if let submittedQuery, submittedQuery != value.trimmingCharacters(in: .whitespacesAndNewlines) {
                self.submittedQuery = nil
                searchRequestID = UUID()
                searchResults = []
                hasSearched = false
                isSearching = false
                errorMessage = nil
                lastSearchQuery = ""
            }
            omnibox.queryChanged(value)
        }
        .task(id: searchRequestID) {
            guard let requested = submittedQuery else {
                isSearching = false
                return
            }
            // V1 é a fonte principal. O /search NDJSON é fallback para Render ainda
            // não atualizado, timeouts ou falta de resultados.
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, requested == submittedQuery else { return }
            if !omnibox.results.isEmpty {
                hasSearched = true
                isSearching = false
                return
            }
            isSearching = true
            do {
                let found = try await YouTubeSearchService().search(
                    query: requested, serverURL: AudioDownloadManager.apiBaseURL)
                try Task.checkCancellation()
                searchResults = found
                hasSearched = true
                isSearching = false
            } catch {
                guard !Task.isCancelled else { return }
                isSearching = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
