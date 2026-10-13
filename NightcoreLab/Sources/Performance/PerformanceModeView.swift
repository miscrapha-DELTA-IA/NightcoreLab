import SwiftUI
import UIKit

/// UIKit touch-down events avoid a SwiftUI button's release-to-trigger delay.
/// Distinct UIControls allow independent touches on different pads.
private struct PadTouchSurface: UIViewRepresentable {
    let name: String
    let onDown: () -> Void

    final class Coordinator: NSObject {
        var onDown: () -> Void
        init(_ onDown: @escaping () -> Void) { self.onDown = onDown }
        @objc func down() { onDown() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onDown) }

    func makeUIView(context: Context) -> UIControl {
        let control = UIControl()
        control.isExclusiveTouch = false
        control.isMultipleTouchEnabled = true
        control.isAccessibilityElement = true
        control.accessibilityTraits = .button
        control.accessibilityLabel = "Tocar \(name)"
        control.addTarget(context.coordinator,
                          action: #selector(Coordinator.down), for: .touchDown)
        return control
    }

    func updateUIView(_ uiView: UIControl, context: Context) {
        context.coordinator.onDown = onDown
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
    @State private var lastHitID: String?
    @State private var hits = 0

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
                    }

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
                                else { recorder.start() }
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
                               let payload = recorder.shareJSON() {
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
                        Text("A gravação salva somente ações e tempos em memória; o áudio final com pads e o vídeo serão integrados ao export em etapa própria.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))

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
        .onDisappear {
            recorder.stop()
            audio.stopPerformancePads()
        }
    }

    private func pad(_ sample: SampleDescriptor) -> some View {
        let active = lastHitID == sample.id
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
            PadTouchSurface(name: sample.name) { strike(sample) }
        }
        .accessibilityIdentifier("performance.pad.\(sample.id)")
    }

    private func strike(_ sample: SampleDescriptor) {
        let velocity = sample.defaultVelocity
        guard audio.triggerPad(sample.id, velocity: velocity) else { return }
        recorder.append(sample, velocity: velocity,
                        sourceTime: audio.isPlaying ? audio.playbackTime : nil)
        lastHitID = sample.id
        hits &+= 1
        if haptics {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
        default: return "waveform.path"
        }
    }
}
