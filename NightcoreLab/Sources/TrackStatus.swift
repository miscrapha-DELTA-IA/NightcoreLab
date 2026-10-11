import SwiftUI

/// Visual transport state, deliberately kept out of Track's persisted metadata.
enum TrackStatus: String, Codable {
    case none
    case downloading
    case downloaded

    static func resolve(cached: Bool, downloading: Bool) -> TrackStatus {
        if cached { return .downloaded }
        return downloading ? .downloading : .none
    }

    var shortDescription: String {
        switch self {
        case .none: return "Tocar agora"
        case .downloading: return "Baixando áudio…"
        case .downloaded: return "Disponível offline"
        }
    }
}

struct TrackStatusIndicator: View {
    let status: TrackStatus
    let accent: Color

    var body: some View {
        Group {
            switch status {
            case .none:
                Image(systemName: "play.circle")
                    .foregroundStyle(accent)
            case .downloading:
                ProgressView()
                    .controlSize(.small)
                    .tint(accent)
            case .downloaded:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green.opacity(0.85))
            }
        }
        .accessibilityLabel(status.shortDescription)
    }
}
