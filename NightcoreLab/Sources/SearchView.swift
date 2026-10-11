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
    let isLoadingSuggestions: Bool
    let canRefreshSuggestions: Bool
    let onRefreshSuggestions: () -> Void
    let onSelect: (Track, [Track]) -> Void
    let onLink: (String) -> Void
    let onServerSettings: () -> Void
    @Binding var isDiscoverExpanded: Bool
    let isPresented: Bool
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
    @FocusState private var isFocused: Bool

    private var typedText: String? {
        if case let .text(text) = OmniboxIntent.classify(query), text.count >= 2 { return text }
        return nil
    }
    private var isSearchMode: Bool { submittedQuery != nil || typedText != nil }
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

    private func showSuggestions() {
        searchExpansionOverride = nil
        lastSearchQuery = ""
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
                    tint: theme.accent
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
                                    Button {
                                        isFocused = false
                                        // Store frecency for instant local suggestions next time.
                                        if let hit = omnibox.results.first(where: { $0.id == track.id }) {
                                            omnibox.recordPlay(hit)
                                        }
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
                                        }
                                        .frame(width: 152)
                                    }
                                    .buttonStyle(.plain)
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
            omnibox.useHistoryStore(playHistory)
            if let base = URL(string: AudioDownloadManager.apiBaseURL) { omnibox.useServer(base) }
            guard !hasRestoredQuery else { return }
            hasRestoredQuery = true
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
            if !presented { isFocused = false }
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
