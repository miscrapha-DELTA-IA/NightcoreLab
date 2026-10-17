import Observation
import SwiftUI

/// Four instant, phase-preserving masking controls in Música.
struct StemMixerControls: View {
    let audio: AudioEngineManager
    @State private var nativeTest = NativeStemTestState()

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("STEMS").font(.caption.bold()).tracking(1.2)
                Spacer()
                Button("Restaurar 100%") { audio.resetStemLevels() }
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("stem.reset")
            }
            Text("Ajuste instantâneo ao vivo · sem preparar a música")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(StemKind.allCases) { kind in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(kind.title).font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(Int((audio.stemLevels[kind] ?? 1) * 100))%")
                            .font(.caption.monospacedDigit())
                    }
                    Slider(value: Binding(
                        get: { Double(audio.stemLevels[kind] ?? 1) },
                        set: { audio.setStemLevel(kind, level: Float($0)) }),
                        in: 0...2)
                        .accessibilityIdentifier("stem.level.\(kind.rawValue)")
                }
            }
            Text("Máscaras locais aproximadas. Algumas frequências e instrumentos podem se sobrepor.")
                .font(.caption2).foregroundStyle(.secondary)

            Divider()
            Text("Separação espectral nativa · teste IPA")
                .font(.caption.bold())
            Button(nativeTest.isPreparing ? "Processando…" : "Preparar instrumental e voz") {
                nativeTest.prepare(source: audio.visualAnalysisURL)
            }
            .disabled(nativeTest.isPreparing || audio.visualAnalysisURL == nil)
            .accessibilityIdentifier("stem.native.prepare")
            if nativeTest.isPreparing {
                ProgressView(value: Double(nativeTest.progress), total: 100) {
                    Text("Separando no iPhone · \(nativeTest.progress)%")
                }
                .accessibilityIdentifier("stem.native.progress")
            }
            if let instrumental = nativeTest.asset?.urls[.instrumental],
               let vocals = nativeTest.asset?.urls[.vocal],
               let asset = nativeTest.asset {
                HStack {
                    Button("Ouvir instrumental") { nativeTest.select(.instrumental, asset: asset, audio: audio) }
                        .accessibilityIdentifier("stem.native.playInstrumental")
                    Button("Ouvir voz") { nativeTest.select(.vocal, asset: asset, audio: audio) }
                        .accessibilityIdentifier("stem.native.playVocals")
                }
                Button("Voltar à música original") { nativeTest.select(nil, asset: asset, audio: audio) }
                    .disabled(audio.nativeStemPreview == nil)
                    .accessibilityIdentifier("stem.native.playOriginal")
                ShareLink(item: instrumental) { Label("Instrumental (.caf)", systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("stem.native.instrumental")
                ShareLink(item: vocals) { Label("Voz extraída (.caf)", systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("stem.native.vocals")
            }
            if let message = nativeTest.message {
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("music.stemMixer")
        .onChange(of: audio.playbackSourceRevision) { _, _ in nativeTest.reset() }
    }
}

@MainActor @Observable
private final class NativeStemTestState {
    private(set) var progress = 0
    private(set) var isPreparing = false
    private(set) var asset: StemAsset?
    private(set) var message: String?
    @ObservationIgnored private var sourceURL: URL?
    @ObservationIgnored private var task: Task<Void, Never>?

    func reset() {
        task?.cancel()
        task = nil
        sourceURL = nil
        asset = nil
        message = nil
        progress = 0
        isPreparing = false
    }

    func prepare(source: URL?) {
        guard let source, source.isFileURL else {
            message = "Carregue uma música local antes de separar."
            return
        }
        reset()
        sourceURL = source
        isPreparing = true
        task = Task { [weak self] in
            do {
                let result = try await StemSplitterEngine.prepare(
                    source: source, cacheFolder: TrackAudioCache.stemDirectory(for: source)) {
                    percent in
                    Task { @MainActor [weak self] in
                        guard self?.sourceURL == source else { return }
                        self?.progress = percent
                    }
                }
                guard !Task.isCancelled, self?.sourceURL == source else { return }
                self?.asset = result
                self?.progress = 100
                self?.message = "Arquivos locais prontos. Compartilhe para ouvir ou salvar no aparelho."
            } catch {
                guard !Task.isCancelled, self?.sourceURL == source else { return }
                self?.message = "Não foi possível separar a música: \(error.localizedDescription)"
            }
            self?.isPreparing = false
            self?.task = nil
        }
    }

    func select(_ kind: StemKind?, asset: StemAsset, audio: AudioEngineManager) {
        guard let sourceURL else { return }
        do {
            try audio.setNativeStemPreview(kind, asset: asset, expectedSource: sourceURL)
            message = kind == nil ? "Música original restaurada." :
                "O player agora usa \(kind == .instrumental ? "instrumental" : "voz") na mesma posição."
        } catch {
            message = "Não foi possível trocar a faixa: \(error.localizedDescription)"
        }
    }
}
