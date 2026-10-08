import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var audio = AudioEngineManager()

    @State private var speed: Float = 1.0
    @State private var reverb: Float = 0
    @State private var bass: Float = 0
    @State private var keepOriginalPitch = false

    @State private var showImporter = false
    @State private var exportFormat: ExportFormat = .m4a
    @State private var shareItem: ShareItem?
    @State private var errorMessage: String?

    @AppStorage(TelemetryManager.enabledKey) private var telemetryEnabled = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    // Troque pelo seu link (Ko-fi, GitHub Sponsors, página com QR Code do Pix…)
    private let donationURL = URL(string: "https://ko-fi.com/SEU_USUARIO")!

    /// Tom resultante: 0 se "Manter o tom original", senão acompanha a velocidade (efeito vinil).
    private var computedPitch: Float {
        keepOriginalPitch ? 0 : 1200 * log2(speed)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    header
                    trackCard
                    presets

                    VStack(spacing: 22) {
                        pitchToggle

                        GiantSlider(title: "Velocidade", value: $speed,
                                    range: AudioEngineManager.speedRange, defaultValue: 1.0,
                                    tint: .pink) { String(format: "%.2f×", $0) }

                        GiantSlider(title: "Reverb", value: $reverb,
                                    range: AudioEngineManager.reverbRange, defaultValue: 0,
                                    tint: .cyan) { String(format: "%.0f%%", $0) }

                        GiantSlider(title: "Baixo", value: $bass,
                                    range: AudioEngineManager.bassRange, defaultValue: 0,
                                    tint: .orange) { String(format: "+%.1f dB", $0) }
                    }
                    .disabled(audio.fileName == nil)
                    .opacity(audio.fileName == nil ? 0.35 : 1)

                    exportSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
        }
        .preferredColorScheme(.dark)
        // Áudio muda instantaneamente enquanto o dedo arrasta
        .onChange(of: speed) { _, value in
            audio.setSpeed(value)
            applyPitch()
        }
        .onChange(of: keepOriginalPitch) { _, _ in applyPitch() }
        .onChange(of: reverb) { _, value in audio.setReverb(value) }
        .onChange(of: bass)   { _, value in audio.setBass(value) }
        .onChange(of: telemetryEnabled) { _, enabled in
            if !enabled { TelemetryManager.shared.discardPending() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { TelemetryManager.shared.flush() }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url): importFile(url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
                .presentationDetents([.medium, .large])
        }
        .alert("Ops", isPresented: Binding(get: { errorMessage != nil },
                                           set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Seções

    private var header: some View {
        HStack {
            Text("Nightcore Lab")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()

            Button {
                openURL(donationURL)
            } label: {
                Image(systemName: "heart.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.pink)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .accessibilityLabel("Apoiar o projeto")

            Button {
                showImporter = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.white))
            }
            .accessibilityLabel("Importar música")
        }
    }

    private var trackCard: some View {
        HStack(spacing: 16) {
            Button {
                audio.togglePlayback()
            } label: {
                Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(.white))
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(audio.fileName == nil)
            .accessibilityLabel(audio.isPlaying ? "Pausar" : "Tocar")

            VStack(alignment: .leading, spacing: 4) {
                Text(audio.fileName ?? "Nenhuma música")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(audio.fileName == nil ? "Toque em + para importar" : durationText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.white.opacity(0.06)))
        .onTapGesture { if audio.fileName == nil { showImporter = true } }
    }

    private var presets: some View {
        HStack(spacing: 10) {
            presetButton("Redefinir", speed: 1.0, reverb: 0, bass: 0)
            presetButton("Lentidão", speed: 0.8, reverb: 45, bass: 0)
            presetButton("Nightcore", speed: 1.25, reverb: 0, bass: 5)
        }
        .disabled(audio.fileName == nil)
    }

    private func presetButton(_ title: String, speed s: Float, reverb r: Float, bass b: Float) -> some View {
        Button {
            withAnimation(.spring(duration: 0.35)) {
                speed = s
                reverb = r
                bass = b
            }
        } label: {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Capsule().fill(.white.opacity(0.08)))
        }
    }

    private var pitchToggle: some View {
        Toggle(isOn: $keepOriginalPitch) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Manter o tom original")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(keepOriginalPitch
                     ? "Só a velocidade muda"
                     : "Tom acompanha a velocidade: \(String(format: "%+.0f", computedPitch)) cents")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                    .contentTransition(.numericText())
            }
        }
        .tint(.pink)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.06)))
        .sensoryFeedback(.impact(weight: .light), trigger: keepOriginalPitch)
    }

    private var exportSection: some View {
        VStack(spacing: 14) {
            Picker("Formato", selection: $exportFormat) {
                ForEach(ExportFormat.allCases) { Text($0.rawValue.uppercased()).tag($0) }
            }
            .pickerStyle(.segmented)

            Button(action: export) {
                ZStack(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(.white.opacity(0.25))
                            .frame(width: geo.size.width * audio.exportProgress)
                    }
                    Text(audio.isExporting
                         ? "Renderizando… \(Int(audio.exportProgress * 100))%"
                         : "Exportar e compartilhar")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                }
                .frame(height: 58)
                .background(Capsule().fill(.white))
                .clipShape(Capsule())
            }
            .disabled(audio.fileName == nil || audio.isExporting)
            .opacity(audio.fileName == nil ? 0.35 : 1)

            Toggle(isOn: $telemetryEnabled) {
                Text("Enviar estatísticas anônimas de uso")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .tint(.gray)
            .padding(.top, 4)
        }
        .padding(.top, 8)
    }

    private var durationText: String {
        let seconds = Int(audio.duration / Double(speed))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: Ações

    private func applyPitch() {
        audio.setPitch(computedPitch)
    }

    private func importFile(_ url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

        do {
            // Copia para o sandbox para não depender do acesso de segurança depois.
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
            try audio.load(url: destination)
            applyPitch()
        } catch {
            TelemetryManager.shared.log(.importFailed)
            errorMessage = "Não foi possível abrir o arquivo: \(error.localizedDescription)"
        }
    }

    private func export() {
        let format = exportFormat
        Task {
            let start = ContinuousClock.now
            do {
                let url = try await audio.exportAudio(format: format)
                let elapsed = ContinuousClock.now - start
                let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                TelemetryManager.shared.log(.exportCompleted(format: format, renderSeconds: seconds))
                shareItem = ShareItem(url: url)
            } catch {
                TelemetryManager.shared.log(.exportFailed(format: format))
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Slider gigante customizado

struct GiantSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let defaultValue: Float
    var tint: Color = .white
    let format: (Float) -> String

    @State private var isDragging = false

    private var span: Float { range.upperBound - range.lowerBound }
    private var progress: CGFloat { CGFloat((value - range.lowerBound) / span) }
    private var defaultPosition: CGFloat { CGFloat((defaultValue - range.lowerBound) / span) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text(format(value))
                    .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.white.opacity(0.06))

                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(tint.gradient)
                        .frame(width: geo.size.width * progress)

                    // Marcador do valor neutro
                    if defaultPosition > 0 && defaultPosition < 1 {
                        Capsule()
                            .fill(.white.opacity(0.35))
                            .frame(width: 2, height: 28)
                            .offset(x: geo.size.width * defaultPosition - 1)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            isDragging = true
                            let fraction = min(max(gesture.location.x / geo.size.width, 0), 1)
                            var newValue = range.lowerBound + Float(fraction) * span
                            // "Imã" no valor neutro (±2%)
                            if abs(newValue - defaultValue) < span * 0.02 { newValue = defaultValue }
                            value = newValue
                        }
                        .onEnded { _ in isDragging = false }
                )
            }
            .frame(height: 72)
            .scaleEffect(isDragging ? 1.02 : 1)
            .animation(.spring(duration: 0.25), value: isDragging)
            .sensoryFeedback(.selection, trigger: value == defaultValue)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            let step = span / 20
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
        }
    }
}

// MARK: - Share sheet

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    ContentView()
}
