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
    @AppStorage("lastSearchQuery") private var lastSearchQuery = ""
    @State private var hasRestoredQuery = false
    @State private var query = ""
    @State private var searchResults: [Track] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var hasSearched = false
    @State private var submittedQuery: String?
    @State private var searchRequestID = UUID()
    @FocusState private var isFocused: Bool

    private var isSearchMode: Bool { submittedQuery != nil }
    private var displayedTracks: [Track] {
        DiscoveryPresentation.visibleTracks(searchQuery: submittedQuery,
                                            searchResults: searchResults, suggestions: suggestedTracks)
    }

    private func showSuggestions() {
        lastSearchQuery = ""
        query = ""
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
        if value.lowercased().hasPrefix("http") ||
            value.lowercased().contains("youtu.be") ||
            value.lowercased().contains("youtube.com") {
            submittedQuery = nil
            searchRequestID = UUID()
            query = ""
            onLink(value)
        } else {
            lastSearchQuery = value
            submittedQuery = value
            searchRequestID = UUID()
        }
    }

    var body: some View {
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
                if isSearching || downloader.isDownloading { ProgressView().tint(theme.accent) }
                if !query.isEmpty {
                    Button { showSuggestions() } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Limpar busca")
                }
            }
            .padding(14)
            .glassSurface(RoundedRectangle(cornerRadius: 16), theme: theme, depth: 0.6)

            HStack {
                Label("DESCOBRIR", systemImage: "sparkles")
                    .font(.caption.weight(.heavy))
                    .tracking(1.4)
                    .foregroundStyle(theme.accent)
                Spacer()
                if isSearchMode {
                    Button("Sugestões") { showSuggestions() }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.accent)
                        .accessibilityLabel("Voltar às sugestões")
                } else if canRefreshSuggestions {
                    Button(action: onRefreshSuggestions) {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(theme.accent)
                    }
                    .accessibilityLabel("Atualizar sugestões")
                }
            }

            if let errorMessage, isSearchMode {
                Text(errorMessage).font(.caption).foregroundStyle(.secondary)
            } else if isSearchMode && hasSearched && searchResults.isEmpty && !isSearching {
                Text("Nenhuma música encontrada. Experimente outro termo.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !isSearchMode && suggestedTracks.isEmpty && !isLoadingSuggestions {
                Text("Escolha uma música para descobrir faixas relacionadas.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if (isSearchMode && isSearching) || (!isSearchMode && isLoadingSuggestions) {
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
                                // Search/discovery never append all results to the playback queue.
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
        .onAppear {
            guard !hasRestoredQuery else { return }
            hasRestoredQuery = true
            let previous = lastSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !previous.isEmpty, submittedQuery == nil, searchResults.isEmpty else { return }
            // A deliberate saved text search is restored once, never on every keystroke.
            query = previous
            submittedQuery = previous
            searchRequestID = UUID()
        }
        .task(id: searchRequestID) {
            guard let requested = submittedQuery else {
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
