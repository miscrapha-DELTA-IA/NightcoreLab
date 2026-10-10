import SwiftUI
import SDWebImageSwiftUI

struct SearchView: View {
    @ObservedObject var downloader: AudioDownloadManager
    let theme: AppTheme
    let isEnabled: Bool
    let onSelect: (Track, [Track]) -> Void
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var hasSearched = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.accent)
                TextField("Buscar músicas no YouTube", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($isFocused)
                    .onSubmit { isFocused = false }
                if isSearching { ProgressView().tint(theme.accent) }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Limpar busca")
                }
            }
            .padding(14)
            .glassSurface(RoundedRectangle(cornerRadius: 16), theme: theme, depth: 0.6)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.secondary)
            } else if hasSearched && results.isEmpty && !isSearching {
                Text("Nenhuma música encontrada.").font(.caption).foregroundStyle(.secondary)
            }
            if !results.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(results) { result in
                            let track = downloader.cachedTrack(result)
                            Button {
                                isFocused = false
                                let index = results.firstIndex(where: { $0.id == track.id }) ?? 0
                                onSelect(track, Array(results.dropFirst(index + 1)))
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
                                    Label(track.isCached ? "Pronta para tocar" : "Tocar",
                                          systemImage: track.isCached ? "checkmark.circle.fill" : "play.circle")
                                        .font(.caption2).foregroundStyle(theme.accent)
                                }
                                .frame(width: 152)
                            }
                            .buttonStyle(.plain)
                            .disabled(!isEnabled)
                        }
                    }
                }
            }
        }
        .task(id: query) {
            let requested = query.trimmingCharacters(in: .whitespacesAndNewlines)
            results = []
            errorMessage = nil
            hasSearched = false
            isSearching = false
            guard !requested.isEmpty else { return }
            do {
                try await Task.sleep(for: .milliseconds(400))
                try Task.checkCancellation()
                isSearching = true
                let found = try await YouTubeSearchService().search(query: requested, serverURL: AudioDownloadManager.apiBaseURL)
                try Task.checkCancellation()
                results = found
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
