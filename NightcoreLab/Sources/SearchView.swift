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
    @Bindable var session: SearchSession
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
    var integrated: Bool = false
    @Environment(PanelStore.self) private var panels
    @Environment(PlayHistoryStore.self) private var playHistory
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchExpansionOverride: Bool?
    @AppStorage(AudioDownloadManager.serverURLKey) private var savedServerURL = AudioDownloadManager.defaultServerURL
    @FocusState private var isFocused: Bool

    private var typedText: String? {
        if case let .text(text) = OmniboxIntent.classify(session.query), text.count >= 2 { return text }
        return nil
    }
    private var isSearchMode: Bool { session.submittedQuery != nil || typedText != nil }
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
            if !session.omnibox.results.isEmpty { return session.omnibox.results.map(\.asTrack) }
            // Só usa o fallback da consulta que o usuário realmente submeteu.
            return session.submittedQuery == session.query.trimmingCharacters(in: .whitespacesAndNewlines) ? session.searchResults : []
        }
        return DiscoveryPresentation.visibleTracks(searchQuery: session.submittedQuery,
                                            searchResults: session.searchResults, suggestions: suggestedTracks)
    }

    private func showSuggestions() {
        searchExpansionOverride = nil
        session.query = ""
        session.omnibox.queryChanged("")
        session.searchResults = []
        session.submittedQuery = nil
        session.hasSearched = false
        session.isSearching = false
        session.errorMessage = nil
        session.searchRequestID = UUID()
        isFocused = false
    }

    private var looksLikeLink: Bool {
        let text = session.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.hasPrefix("http") || text.contains("youtu.be") || text.contains("youtube.com")
    }

    private func handleInput(_ input: String) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, isEnabled else { return }
        isFocused = false
        session.errorMessage = nil
        session.searchResults = []
        session.hasSearched = false
        if case let .direct(videoID) = OmniboxIntent.classify(value) {
            session.submittedQuery = nil
            session.searchRequestID = UUID()
            session.query = session.savedQuery
            onLink("https://www.youtube.com/watch?v=\(videoID)")
            return
        }
        if value.lowercased().hasPrefix("http") ||
            value.lowercased().contains("youtu.be") ||
            value.lowercased().contains("youtube.com") {
            session.submittedQuery = nil
            session.searchRequestID = UUID()
            session.query = session.savedQuery
            onLink(value)
        } else {
            // Reveal results for this session without changing either preference.
            searchExpansionOverride = nil
            session.submittedQuery = value
            session.searchRequestID = UUID()
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
                    TextField("Buscar música ou colar link", text: $session.query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($isFocused)
                        .onSubmit { handleInput(session.query) }
                        .disabled(!isEnabled)
                    if session.isSearching || session.omnibox.isSearching || downloader.isDownloading {
                        ProgressView().tint(theme.accent)
                    }
                    if !session.query.isEmpty {
                        Button { showSuggestions() } label: { Image(systemName: "xmark.circle.fill") }
                            .accessibilityLabel("Limpar busca")
                    }
                }
                .padding(14)
                .glassSurface(RoundedRectangle(cornerRadius: 16), theme: theme, depth: 0.6)

                if typedText != nil && session.omnibox.isShowingStaleCache {
                    Text("Resultados salvos · tentando atualizar")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Resultados em cache; atualização em andamento ou indisponível")
                } else if typedText != nil && session.omnibox.lastRequestFailed &&
                            session.omnibox.loadState == .partial {
                    Text("Resultados parciais · um serviço está indisponível")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if typedText != nil && !session.omnibox.suggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(session.omnibox.suggestions.prefix(5), id: \.self) { item in
                                Button {
                                    session.query = item
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
                    if let errorMessage = session.errorMessage, isSearchMode {
                        Text(errorMessage).font(.caption).foregroundStyle(.secondary)
                    } else if isSearchMode && (session.hasSearched || session.omnibox.hasSearched) &&
                              displayedTracks.isEmpty && !session.isSearching && !session.omnibox.isSearching {
                        Text("Nenhuma música encontrada. Experimente outro termo.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !isSearchMode && suggestedTracks.isEmpty && !isLoadingSuggestions {
                        Text("Escolha uma música para descobrir faixas relacionadas.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if (isSearchMode && (session.isSearching || session.omnibox.isSearching)) ||
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
                                                TrackStatusIndicator(status: status, accent: theme.accent)
                                                Text(status.shortDescription)
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
                                    .contextMenu {
                                        Button("Baixar para ouvir offline", systemImage: "arrow.down.circle") {
                                            downloader.downloadForOffline(track)
                                        }
                                        .disabled(status != .none || !isEnabled)
                                        if status == .downloading {
                                            Button("Cancelar download", systemImage: "xmark.circle", role: .destructive) {
                                                downloader.cancelDownload(track)
                                            }
                                        }
                                        if status == .downloaded {
                                            Button("Remover download", systemImage: "trash", role: .destructive) {
                                                downloader.removeDownload(track)
                                            }
                                            .disabled(!downloader.canRemoveDownload(track))
                                        }
                                    }
                                    .disabled(!isEnabled)
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
            session.omnibox.useHistoryStore(playHistory)
            if let base = URL(string: AudioDownloadManager.apiBaseURL) { session.omnibox.useServer(base) }
            guard !session.hasRestoredQuery else { return }
            session.hasRestoredQuery = true
            let previous = session.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !previous.isEmpty, session.submittedQuery == nil, session.searchResults.isEmpty else { return }
            // A deliberate saved text search is restored once, never on every keystroke.
            session.query = previous
            session.omnibox.queryChanged(previous)
            session.submittedQuery = previous
            session.searchRequestID = UUID()
        }
        .onChange(of: savedServerURL) { _, _ in
            if let base = URL(string: AudioDownloadManager.apiBaseURL) {
                session.omnibox.useServer(base)
                session.omnibox.queryChanged(session.query)
            }
        }
        .onChange(of: panels.isHidden(.omnibox)) { _, hidden in
            if hidden { isFocused = false }
        }
        .onChange(of: panels.isZen) { _, zen in
            if zen { isFocused = false }
        }
        .onChange(of: isPresented) { _, presented in
            if !presented { isFocused = false }
        }
        .onChange(of: isFocused) { _, focused in
            if focused { downloader.warmUp() }
        }
        .onChange(of: session.query) { _, value in
            searchExpansionOverride = nil
            // Link/ID colado bypassa ambas as APIs de busca.
            if case let .direct(id) = OmniboxIntent.classify(value), isEnabled {
                session.query = session.savedQuery
                onLink("https://www.youtube.com/watch?v=\(id)")
                return
            }
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                showSuggestions()
                return
            }
            // Editing invalidates a submitted fallback; never show stale results.
            if let submittedQuery = session.submittedQuery, submittedQuery != value.trimmingCharacters(in: .whitespacesAndNewlines) {
                session.submittedQuery = nil
                session.searchRequestID = UUID()
                session.searchResults = []
                session.hasSearched = false
                session.isSearching = false
                session.errorMessage = nil
            }
            session.omnibox.queryChanged(value)
        }
        .task(id: session.searchRequestID) {
            guard let requested = session.submittedQuery else {
                session.isSearching = false
                return
            }
            // V1 é a fonte principal. O /search NDJSON é fallback para Render ainda
            // não atualizado, timeouts ou falta de resultados.
            while session.omnibox.isSearching {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard !Task.isCancelled, requested == session.submittedQuery else { return }
            if !session.omnibox.results.isEmpty {
                session.hasSearched = true
                session.isSearching = false
                return
            }
            session.isSearching = true
            do {
                let found = try await YouTubeSearchService().search(
                    query: requested, serverURL: AudioDownloadManager.apiBaseURL)
                try Task.checkCancellation()
                session.searchResults = found
                session.hasSearched = true
                session.isSearching = false
            } catch {
                guard !Task.isCancelled else { return }
                session.isSearching = false
                session.errorMessage = error.localizedDescription
            }
        }
    }
}
