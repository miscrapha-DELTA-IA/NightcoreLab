import SwiftUI

/// All frequent reads live here, outside the lyrics' scroll/typography tree.
struct KaraokeScoreHUD: View {
    let session: KaraokeScoringSession
    var accent: Color = .cyan
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if session.isHUDVisible {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.mode == .passive ? "RITMO DA FAIXA · SEM MICROFONE" : (session.mode == .simulation ? "SIMULAÇÃO" : "CANTO AO VIVO"))
                            .font(.system(size: 9, weight: .bold))
                        Text(session.snapshot.totalScore, format: .number)
                            .font(.title3.bold().monospacedDigit())
                            .contentTransition(.numericText())
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 3) {
                        if session.mode == .microphone {
                            HStack(spacing: 5) {
                                Image(systemName: "mic.fill")
                                GeometryReader { size in
                                    Capsule().fill(.white.opacity(0.16))
                                        .overlay(alignment: .leading) {
                                            Capsule().fill(accent)
                                                .frame(width: size.size.width * session.liveMicLevel)
                                        }
                                }
                                .frame(width: 40, height: 5)
                            }
                            .accessibilityLabel("Nível do microfone")
                            .accessibilityValue("\(Int(session.liveMicLevel * 100)) por cento")
                            .accessibilityIdentifier("karaoke.liveMicLevel")
                        }
                        Text("\(session.snapshot.multiplier)x · \(session.snapshot.streakCombo) combo")
                            .font(.caption.bold().monospacedDigit())
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(accent.opacity(0.22), in: Capsule())
                        Text(session.snapshot.hasHarmonicReference ? "Ritmo + afinação" : "Ritmo e presença · tom indisponível")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: session.snapshot.vocalAccuracy)
                    .tint(accent)
                    .accessibilityLabel(session.mode == .passive ? "Sincronia da faixa" : "Precisão vocal")
                    .accessibilityValue("\(Int(session.snapshot.vocalAccuracy * 100)) por cento")
                if session.snapshot.isFinished {
                    KaraokeScoreSummary(snapshot: session.snapshot, simulation: session.mode != .microphone)
                }
            }
            .padding(12)
            .foregroundStyle(.white)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(accent.opacity(0.3)))
            .shadow(color: accent.opacity(session.snapshot.vocalAccuracy * 0.15), radius: 8)
            .safeAreaInset(edge: .bottom, spacing: 4) {
                Text(session.judgmentVisible ?
                     (session.mode == .microphone && session.snapshot.lastVerseWasSilent ?
                        "Cante no mic 🎤" : session.snapshot.lastVerseRating?.rawValue ?? "") : "")
                    .font(.caption.bold())
                    .foregroundStyle(accent)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(session.judgmentVisible ? 0.7 : 0), in: Capsule())
                    .allowsHitTesting(false)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: session.snapshot.totalScore)
            .padding(.horizontal, 18).padding(.top, 4)
            .accessibilityIdentifier("karaoke.scoreHUD")
        }
    }
}

private struct KaraokeScoreSummary: View {
    let snapshot: KaraokeScoreSnapshot
    let simulation: Bool
    var body: some View {
        VStack(spacing: 7) {
            Divider()
            Text("Nota \(snapshot.rank) · \(Int(snapshot.accuracyPercentage.rounded()))%")
                .font(.headline)
            Text("Maior combo: \(snapshot.bestCombo) · \(snapshot.totalScore) pontos")
                .font(.caption)
            ShareLink(item: KaraokeScoreShareComposer.text(snapshot, simulation: simulation)) {
                Label("Compartilhar resultado", systemImage: "square.and.arrow.up")
                    .font(.caption.bold())
            }
        }
        .accessibilityIdentifier("karaoke.scoreSummary")
    }
}

/// Opt-in controls publish only discrete changes; a microphone permission
/// prompt is never triggered by entering the existing lyrics-only mode.
struct KaraokeScoringControls: View {
    let store: LyricsStore
    let audio: AudioEngineManager
    let clock: PlaybackClock
    let accent: Color
    @State private var request: Task<Void, Never>?
    @State private var requesting = false
    @State private var showsError = false

    var body: some View {
        Menu {
            Button("Pontuar com microfone", systemImage: "mic.badge.plus") { startMicrophone() }
                .disabled(requesting || store.status != .ready)
            Button("Experimentar simulação", systemImage: "play.rectangle") {
                request?.cancel(); audio.endKaraokeMicrophone()
                requesting = false
                store.scoring.start(mode: .simulation, lines: store.lines,
                                    at: clock.lyricTime + store.userOffset)
                audio.karaokeCompletion = { [weak session = store.scoring] in session?.finish() }
            }
            .disabled(store.status != .ready)
            Button("Desligar pontuação", systemImage: "mic.slash") {
                request?.cancel(); requesting = false
                audio.endKaraokeMicrophone(); store.scoring.stop()
            }
            Text("Use fones para evitar captar a música no microfone.")
        } label: {
            Image(systemName: store.scoring.mode == .off ? "trophy" : "trophy.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("Pontuação do karaokê")
        .alert("Permissão do microfone desativada", isPresented: $showsError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Autorize o microfone nos Ajustes ou escolha Experimentar simulação. Nenhum resultado simulado é apresentado como canto real.")
        }
        .onChange(of: audio.karaokeMicrophoneActive) { _, active in
            if !active, store.scoring.mode == .microphone, !store.scoring.snapshot.isFinished {
                store.scoring.stop(message: "Microfone interrompido. Ative novamente para começar.")
            }
        }
        .onChange(of: store.scoring.mode) { _, mode in
            if mode == .off { audio.endKaraokeMicrophone() }
        }
        .onDisappear {
            request?.cancel()
        }
    }

    private func startMicrophone() {
        request?.cancel()
        requesting = true
        let revision = audio.playbackSourceRevision
        request = Task { @MainActor in
            let allowed = await audio.beginKaraokeMicrophone()
            guard !Task.isCancelled else { return }
            requesting = false
            guard store.scoring.isPresented, audio.playbackSourceRevision == revision else {
                audio.endKaraokeMicrophone(); return
            }
            guard allowed else { showsError = audio.microphonePermissionDenied; return }
            store.scoring.start(mode: .microphone, lines: store.lines,
                                at: clock.lyricTime + store.userOffset)
            store.scoring.microphoneFrame = { [weak audio] _ in audio?.karaokeVoiceFrame() ?? .silence }
            audio.karaokeCompletion = { [weak session = store.scoring] in session?.finish() }
        }
    }
}


/// Offline, text-only share contract. Never represents simulated scores as
/// a recorded microphone performance.
enum KaraokeScoreShareComposer {
    static func text(_ snapshot: KaraokeScoreSnapshot, simulation: Bool) -> String {
        let mode = simulation ? "SIMULAÇÃO de karaokê" : "Canto ao vivo"
        return [
            "Nightcore Lab · \(mode)",
            "Nota \(snapshot.rank) · \(Int(snapshot.accuracyPercentage.rounded()))%",
            "\(snapshot.totalScore) pontos · maior combo \(snapshot.bestCombo)x",
            snapshot.hasHarmonicReference ? "Ritmo e afinação" : "Avaliação rítmica"
        ].joined(separator: "\n")
    }
}
