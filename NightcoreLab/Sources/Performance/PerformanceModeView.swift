import SwiftUI
import UIKit

/// UIKit touch-down events avoid a SwiftUI button's release-to-trigger delay.
/// Distinct UIControls allow independent touches on different pads.
private struct PadTouchSurface: UIViewRepresentable {
    let name: String
    let onDown: () -> Void
    let onUp: () -> Void

    final class Coordinator: NSObject {
        var onDown: () -> Void
        var onUp: () -> Void
        init(_ onDown: @escaping () -> Void, _ onUp: @escaping () -> Void) {
            self.onDown = onDown
            self.onUp = onUp
        }
        @objc func down() { onDown() }
        @objc func up() { onUp() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onDown, onUp) }

    func makeUIView(context: Context) -> UIControl {
        let control = UIControl()
        control.isExclusiveTouch = false
        control.isMultipleTouchEnabled = true
        control.isAccessibilityElement = true
        control.accessibilityTraits = .button
        control.accessibilityLabel = "Tocar \(name)"
        control.addTarget(context.coordinator,
                          action: #selector(Coordinator.down), for: .touchDown)
        control.addTarget(context.coordinator, action: #selector(Coordinator.up),
                          for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        return control
    }

    func updateUIView(_ uiView: UIControl, context: Context) {
        context.coordinator.onDown = onDown
        context.coordinator.onUp = onUp
        uiView.accessibilityLabel = "Tocar \(name)"
    }
}

/// Only visible after explicitly entering Performance Mode. Never overlays
/// the premium Player or Karaoke. Its sound is produced by AudioEngineManager.
struct PerformanceModeView: View {
    let audio: AudioEngineManager
    let accent: Color

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var recorder = PerformanceRecorder()
    @State private var haptics = false
    @State private var heldPads: Set<String> = []
    @State private var recordedSourceRevision: Int?
    @State private var isRenderingAudio = false
    @State private var exportedAudio: URL?
    @State private var renderError: String?
    @State private var exportTask: Task<Void, Never>?
    @State private var clipTask: Task<Void, Never>?
    @State private var clipStart: Double = 0
    @State private var clipLength: Double = 2
    @State private var sourceClip: PerformanceSourceClip?
    @State private var recordedClip: PerformanceSourceClip?
    @State private var preparingClip = false
    @State private var confirmSharingRights = false

    private let grid = [GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("LIVE PERFORMANCE")
                            .font(.caption.weight(.heavy)).tracking(3)
                            .foregroundStyle(accent)
                        Text("Toque. Misture. Crie.")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                        Text("7 sons originais, pré-carregados. Toque com vários dedos enquanto a música continua.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.63))
                    }

                    HStack(spacing: 8) {
                        Image(systemName: audio.isPlaying ? "waveform" : "music.note")
                            .foregroundStyle(accent)
                        Text(audio.isPlaying ? "Música + pads" : "Pads independentes")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("12 VOZES")
                            .font(.caption2.monospaced().weight(.bold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(12)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))

                    LazyVGrid(columns: grid, spacing: 12) {
                        ForEach(audio.performanceKit.samples) { sample in
                            pad(sample)
                        }
                        if let sourceClip {
                            pad(sourceClip.descriptor)
                        }
                    }

                    sourceClipPicker

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "record.circle")
                                .foregroundStyle(recorder.isRecording ? .red : accent)
                            Text("CAPTURAR EVENTOS")
                                .font(.caption.weight(.bold)).tracking(1.6)
                            Spacer()
                            Text("\(recorder.events.count) ações")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Button {
                                if recorder.isRecording { recorder.stop() }
                                else {
                                    recordedSourceRevision = audio.playbackSourceRevision
                                    recordedClip = sourceClip
                                    recorder.start()
                                    exportedAudio = nil
                                }
                            } label: {
                                Label(recorder.isRecording ? "Parar" : "Gravar",
                                      systemImage: recorder.isRecording ? "stop.fill" : "record.circle")
                                    .frame(maxWidth: .infinity)
                                    .padding(12)
                                    .background(recorder.isRecording ? Color.red.opacity(0.22) :
                                        accent.opacity(0.20), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .accessibilityIdentifier("performance.record")

                            if !recorder.events.isEmpty && !recorder.isRecording,
                               let payload = recorder.shareJSON(sourceClip: recordedClip) {
                                ShareLink(item: payload,
                                          subject: Text("NightcoreLab Performance Events"),
                                          message: Text("Sequência de pads NightcoreLab (JSON v1)")) {
                                    Label("Compartilhar eventos", systemImage: "square.and.arrow.up")
                                        .padding(12)
                                        .background(.white.opacity(0.08),
                                                    in: RoundedRectangle(cornerRadius: 12))
                                }
                                .accessibilityIdentifier("performance.shareEvents")
                            }
                        }
                        Text("A captura guarda ações e tempos em memória. Você pode compartilhar os eventos em JSON e, com música carregada, renderizar um M4A com os pads. Exportação de Story com pads é etapa posterior.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))

                    if !recorder.isRecording && !recorder.events.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Button {
                                renderPerformanceAudio()
                            } label: {
                                HStack {
                                    Image(systemName: "waveform.badge.plus")
                                    Text(isRenderingAudio ? "Renderizando áudio…" : "Criar música + pads (M4A)")
                                    Spacer()
                                    if isRenderingAudio { ProgressView() }
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity)
                                .background(accent.opacity(0.18),
                                            in: RoundedRectangle(cornerRadius: 12))
                            }
                            .disabled(isRenderingAudio || audio.isExporting ||
                                      audio.fileName == nil ||
                                      recordedSourceRevision != audio.playbackSourceRevision)
                            .accessibilityIdentifier("performance.renderAudio")

                            if let exportedAudio {
                                ShareLink(item: exportedAudio) {
                                    Label("Compartilhar áudio com pads", systemImage: "square.and.arrow.up")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .accessibilityIdentifier("performance.shareAudio")
                            }
                            if audio.fileName == nil {
                                Text("Carregue uma música para exportar o áudio misturado. Os pads funcionam sem música.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            } else if recordedSourceRevision != audio.playbackSourceRevision {
                                Text("A faixa foi alterada. Inicie uma nova gravação para exportar áudio com segurança.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(14)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                    }

                    Toggle("Feedback tátil", isOn: $haptics)
                        .font(.subheadline)
                        .tint(accent)
                    Text("Os sons são sínteses originais do app — nenhum sample comercial.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.50))
                }
                .padding(20)
            }
            .background(Color(red: 0.045, green: 0.055, blue: 0.075))
            .navigationTitle("Performance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fechar") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .alert("Exportação da performance", isPresented: Binding(
            get: { renderError != nil },
            set: { if !$0 { renderError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(renderError ?? "")
        }
        .onChange(of: audio.playbackSourceRevision) { _, _ in
            clipTask?.cancel()
            preparingClip = false
            sourceClip = nil
            recordedClip = nil
            confirmSharingRights = false
            if recorder.isRecording { recorder.stop() }
            exportedAudio = nil
        }
        .onDisappear {
            clipTask?.cancel()
            exportTask?.cancel()
            heldPads.removeAll()
            recorder.stop()
            audio.stopPerformancePads()
        }
    }

    @ViewBuilder
    private var sourceClipPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("SAMPLE PICKER", systemImage: "waveform.badge.plus")
                    .font(.caption.weight(.bold)).tracking(1.5)
                Spacer()
                Text("0,25–5 s")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if audio.duration >= PerformanceSourceClip.minLength {
                let lastStart = max(0, audio.duration - PerformanceSourceClip.minLength)
                Text("Início: \(clipStart, specifier: "%.2f") s")
                    .font(.caption)
                Slider(value: $clipStart, in: 0...lastStart)
                    .tint(accent)
                    .accessibilityIdentifier("performance.clipStart")
                let upperLength = max(PerformanceSourceClip.minLength,
                                      min(PerformanceSourceClip.maxLength,
                                          audio.duration - clipStart))
                Text("Duração: \(min(clipLength, upperLength), specifier: "%.2f") s")
                    .font(.caption)
                Slider(value: $clipLength,
                       in: PerformanceSourceClip.minLength...upperLength)
                    .tint(accent)
                    .accessibilityIdentifier("performance.clipLength")

                Toggle("Tenho autorização para usar e compartilhar esse trecho",
                       isOn: $confirmSharingRights)
                    .font(.caption)
                    .tint(accent)
                Button {
                    prepareSourceClip()
                } label: {
                    HStack {
                        Label(sourceClip == nil ? "Atribuir ao pad CLIP" : "Atualizar pad CLIP",
                              systemImage: "square.stack.3d.up")
                        Spacer()
                        if preparingClip { ProgressView() }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(preparingClip || recorder.isRecording ||
                          isRenderingAudio || !confirmSharingRights)
                .accessibilityIdentifier("performance.assignClip")

                if sourceClip != nil {
                    Text("Pad CLIP pronto: toque no oitavo pad. O trecho usa PCM local e não é salvo permanentemente.")
                        .font(.caption2)
                        .foregroundStyle(accent)
                }
            } else {
                Text("Carregue uma música local para selecionar um trecho. O kit original funciona sem música.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private func prepareSourceClip() {
        guard let url = audio.visualAnalysisURL, url.isFileURL,
              !preparingClip, !recorder.isRecording, confirmSharingRights else { return }
        let revision = audio.playbackSourceRevision
        let duration = min(clipLength, audio.duration - clipStart,
                           PerformanceSourceClip.maxLength)
        guard duration >= PerformanceSourceClip.minLength else { return }
        preparingClip = true
        clipTask?.cancel()
        clipTask = Task { @MainActor in
            defer { preparingClip = false; clipTask = nil }
            do {
                let clip = try await audio.assignPerformanceSourceClip(
                    startTime: clipStart, duration: duration,
                    expectedRevision: revision)
                guard !Task.isCancelled,
                      revision == audio.playbackSourceRevision else { return }
                sourceClip = clip
                recordedClip = nil
                // A new assignment changes the pad material. Old events
                // must not silently replay against a different source clip.
                recorder.start()
                recorder.stop()
                exportedAudio = nil
            } catch is CancellationError {
                // Track replacement or dismissal invalidated preparation.
            } catch {
                renderError = "Não foi possível preparar o trecho: \(error.localizedDescription)"
            }
        }
    }

    private func pad(_ sample: SampleDescriptor) -> some View {
        let active = heldPads.contains(sample.id)
        return ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(active ? accent.opacity(0.22) : .white.opacity(0.06))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(active ? accent.opacity(0.8) :
                                        .white.opacity(0.14), lineWidth: 1.5)
                }

            VStack(spacing: 9) {
                Image(systemName: symbol(for: sample.id))
                    .font(.title2)
                    .foregroundStyle(active ? accent : .white.opacity(0.84))
                Text(sample.name)
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .tracking(0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.white)
            }
            .allowsHitTesting(false)
        }
        .frame(height: 102)
        .overlay {
            PadTouchSurface(name: sample.name, onDown: {
                heldPads.insert(sample.id)
                strike(sample)
            }, onUp: {
                heldPads.remove(sample.id)
            })
        }
        .accessibilityIdentifier("performance.pad.\(sample.id)")
    }

    private func strike(_ sample: SampleDescriptor) {
        let velocity = sample.defaultVelocity
        guard audio.triggerPad(sample.id, velocity: velocity) else { return }
        recorder.append(sample, velocity: velocity,
                        sourceTime: audio.isPlaying ? audio.playbackTime : nil)
        exportedAudio = nil
        if haptics {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func renderPerformanceAudio() {
        guard !isRenderingAudio, audio.fileName != nil,
              recordedSourceRevision == audio.playbackSourceRevision else { return }
        let frozen = recorder.timeline(sourceClip: recordedClip)
        guard frozen.isValid && !frozen.events.isEmpty else { return }
        isRenderingAudio = true
        exportedAudio = nil
        renderError = nil
        exportTask = Task { @MainActor in
            defer { isRenderingAudio = false; exportTask = nil }
            do {
                let result = try await audio.exportPerformanceAudio(timeline: frozen)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: result)
                    return
                }
                exportedAudio = result
            } catch is CancellationError {
                // The sheet was dismissed; the offline render is cancelled.
            } catch {
                renderError = error.localizedDescription
            }
        }
    }

    private func symbol(for id: String) -> String {
        switch id {
        case "kick": return "circle.circle.fill"
        case "snare": return "circle.hexagongrid.fill"
        case "closed-hat": return "circle.lefthalf.filled"
        case "open-hat": return "circle.righthalf.filled"
        case "clap": return "hands.clap.fill"
        case "crash": return "sparkles"
        case PerformanceSourceClip.slotID: return "waveform.path.ecg"
        default: return "waveform.path"
        }
    }
}
