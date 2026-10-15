import SwiftUI

/// Frozen result for the completed song, independent of later queue changes.
struct KaraokeSummary: Identifiable, Equatable {
    let id = UUID()
    let track: TrackInfo
    let snapshot: KaraokeScoreSnapshot
    let mode: KaraokeScoringSession.Mode

    init?(track: TrackInfo, snapshot: KaraokeScoreSnapshot,
          mode: KaraokeScoringSession.Mode) {
        guard mode != .off, snapshot.isFinished,
              snapshot.judgedVerses > 0 else { return nil }
        self.track = track
        self.snapshot = snapshot
        self.mode = mode
    }

    var grade: String { snapshot.rank }
    var totalScore: Int { snapshot.totalScore }
    var maxCombo: Int { snapshot.bestCombo }
    var accuracy: Int { Int(snapshot.accuracyPercentage.rounded()) }
    var stamp: KaraokePerformanceStamp? {
        KaraokePerformanceStamp(snapshot: snapshot, mode: mode)
    }
}

struct KaraokeResultCard: View {
    let summary: KaraokeSummary
    let theme: AppTheme
    let onShare: () -> Void
    let onReplay: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            NightcoreBrandLockup(theme: theme, iconSize: 30, titleSize: 21)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("RESUMO DA PERFORMANCE")
                .font(.caption.weight(.heavy)).tracking(2)
                .foregroundStyle(theme.accent)
            TrackIdentityPill(title: summary.track.title,
                              artist: summary.track.artist,
                              artworkURL: summary.track.coverURL,
                              thumbnailSize: 56)
            Text(summary.grade)
                .font(.system(size: 70, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 112, height: 112)
                .background(theme.accent.opacity(0.3), in: Circle())
                .overlay(Circle().strokeBorder(theme.accent, lineWidth: 2))
                .shadow(color: theme.accent.opacity(0.65), radius: 20)
                .accessibilityLabel("Nota \(summary.grade)")
            if let stamp = summary.stamp {
                Text(stamp.label)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.accent)
            }
            HStack(spacing: 8) {
                metric("PONTUAÇÃO TOTAL", value: summary.totalScore.formatted())
                metric("COMBO MÁXIMO", value: "x\(min(4, 1 + summary.maxCombo / 3)) · \(summary.maxCombo)")
                metric(summary.mode == .microphone ? "PRECISÃO VOCAL" : "SINCRONIA",
                       value: "\(summary.accuracy)%")
            }
            Button(action: onShare) {
                Label("🔥 Compartilhar Story", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
            .accessibilityIdentifier("karaoke.resultShare")
            Button(action: onReplay) {
                Label("Cantar Novamente", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("karaoke.resultReplay")
        }
        .padding(22)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(theme.accent.opacity(0.45)))
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .accessibilityIdentifier("karaoke.resultCard")
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(spacing: 5) {
            Text(value).font(.headline.monospacedDigit())
                .minimumScaleFactor(0.7).lineLimit(1)
            Text(label).font(.system(size: 8, weight: .bold))
                .multilineTextAlignment(.center).lineLimit(2)
                .foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity, minHeight: 57)
        .padding(4)
        .background(.white.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 12))
    }
}
