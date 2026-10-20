import SwiftUI

/// All frequent reads live here, outside the lyrics' scroll/typography tree.
struct KaraokeScoreHUD: View {
    let session: KaraokeScoringSession
    var accent: Color = .cyan
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if session.isHUDVisible {
            VStack(spacing: 5) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.mode == .simulation ? "SIMULAÇÃO" : "CANTO AO VIVO")
                            .font(.system(size: 9, weight: .bold))
                        Text(session.snapshot.totalScore, format: .number)
                            .font(.subheadline.bold().monospacedDigit())
                            .contentTransition(.numericText())
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(session.snapshot.multiplier)x · \(session.snapshot.streakCombo) combo")
                            .font(.caption.bold().monospacedDigit())
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(accent.opacity(0.22), in: Capsule())
                        Text(session.snapshot.hasHarmonicReference ? "Ritmo + afinação" : "Ritmo e presença · tom indisponível")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: session.snapshot.vocalAccuracy)
                    .tint(accent)
                    .accessibilityLabel("Precisão vocal")
                    .accessibilityValue("\(Int(session.snapshot.vocalAccuracy * 100)) por cento")
            }
            .padding(9)
            .foregroundStyle(.white)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(accent.opacity(0.3)))
            .shadow(color: accent.opacity(session.snapshot.vocalAccuracy * 0.15), radius: 8)
            .overlay(alignment: .bottom) {
                Text(session.judgmentVisible ? session.snapshot.lastVerseRating?.rawValue ?? "" : "")
                    .font(.caption.bold())
                    .foregroundStyle(accent)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(session.judgmentVisible ? 0.7 : 0), in: Capsule())
                    .offset(y: 34)
                    .allowsHitTesting(false)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: session.snapshot.totalScore)
            .frame(maxWidth: 310)
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
    @State private var result: KaraokeScoringSession.Result?

    private var microphoneOn: Bool {
        store.scoring.mode == .microphone && !store.scoring.snapshot.isFinished
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if microphoneOn || requesting { stopMicrophone() }
                else { startMicrophone() }
            } label: {
                Label(requesting ? "Cancelar" : microphoneOn ? "Desligar mic" : "Ligar mic",
                      systemImage: microphoneOn ? "mic.fill" : "mic.slash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(store.status != .ready && !microphoneOn && !requesting)
            .accessibilityLabel(microphoneOn ? "Desligar microfone" : requesting ? "Cancelar ativação do microfone" : "Ligar microfone")
            .accessibilityValue(microphoneOn ? "Ligado" : "Desligado")
            .accessibilityHint("Use fones para evitar captar a música no microfone")
            .accessibilityIdentifier("karaoke.microphoneToggle")
            .contextMenu {
                Button("Experimentar simulação", systemImage: "play.rectangle") {
                    stopMicrophone()
                    store.scoring.start(mode: .simulation, lines: store.lines,
                                        at: clock.lyricTime + store.sourceTimelineOffset(for: clock))
                    audio.karaokeCompletion = { [weak session = store.scoring] in session?.finish() }
                }
                .disabled(store.status != .ready)
            }

            if store.scoring.mode != .off || store.scoring.lastResult != nil {
                Button("Ver resultado") {
                    stopMicrophone()
                    result = store.scoring.lastResult
                }
                .font(.caption.weight(.semibold))
                .frame(minHeight: 44)
                .accessibilityIdentifier("karaoke.viewResult")
            }
        }
        .sheet(item: $result) { saved in
            NavigationStack {
                KaraokeScoreSummary(snapshot: saved.snapshot, simulation: saved.simulation)
                    .padding(24)
                    .navigationTitle(saved.simulation ? "Resultado · simulação" : "Resultado do canto")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Fechar") { result = nil }
                        }
                    }
            }
            .presentationDetents([.medium])
        }
        .alert("Microfone indisponível", isPresented: $showsError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Autorize o microfone nos Ajustes para pontuar seu canto.")
        }
        .onChange(of: audio.karaokeMicrophoneActive) { _, active in
            if !active, store.scoring.mode == .microphone, !store.scoring.snapshot.isFinished {
                store.scoring.stop(message: "Microfone interrompido. Ative novamente para começar.")
            }
        }
        .onChange(of: store.scoring.mode) { _, mode in
            if mode == .off { audio.endKaraokeMicrophone() }
        }
        .onChange(of: store.scoring.snapshot.isFinished) { _, finished in
            if finished { audio.endKaraokeMicrophone() }
        }
        .onDisappear {
            stopMicrophone()
        }
    }

    private func stopMicrophone() {
        request?.cancel(); requesting = false
        store.scoring.stop()
        audio.endKaraokeMicrophone()
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
            guard allowed else { showsError = true; return }
            store.scoring.start(mode: .microphone, lines: store.lines,
                                at: clock.lyricTime + store.sourceTimelineOffset(for: clock))
            store.scoring.microphoneFrame = { [weak audio] _ in audio?.karaokeVoiceFrame() ?? .silence }
            audio.karaokeCompletion = { [weak session = store.scoring] in session?.finish() }
        }
    }
}
