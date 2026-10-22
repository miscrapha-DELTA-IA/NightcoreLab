import Foundation
import Observation

/// Owned by the player, so hiding search or opening karaoke keeps its results.
@MainActor @Observable
final class SearchSession {
    var query: String {
        didSet {
            switch OmniboxIntent.classify(query) {
            case .text(let text): defaults.set(text, forKey: Self.queryKey)
            case .empty: defaults.removeObject(forKey: Self.queryKey)
            case .direct: break
            }
        }
    }
    let omnibox: OmniboxEngine
    var hasRestoredQuery = false
    /// Last explicitly selected drawer tab belongs to the playback session, not to
    /// the conditional SwiftUI view. Closing or selecting a song must not reset it.
    var hubTab: DrawerHubTab = .mix
    var searchResults: [Track] = []
    var isSearching = false
    var errorMessage: String?
    var hasSearched = false
    var submittedQuery: String?
    var searchRequestID = UUID()
    static let queryKey = "lastSearchQuery"
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, omnibox: OmniboxEngine? = nil) {
        self.defaults = defaults
        self.query = defaults.string(forKey: Self.queryKey) ?? ""
        self.omnibox = omnibox ?? OmniboxEngine(baseURL:
            URL(string: AudioDownloadManager.apiBaseURL) ?? URL(string: AudioDownloadManager.defaultServerURL)!)
    }

    var savedQuery: String { defaults.string(forKey: Self.queryKey) ?? "" }
}
