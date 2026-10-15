import SwiftUI

struct StemMixerControls: View {
    let audio: AudioEngineManager
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Stem Mixer").font(.headline)
                Spacer()
                Toggle("Ativo", isOn: Binding(
                    get: { audio.stemMixEnabled },
                    set: { audio.setStemMixerEnabled($0) }))
                    .labelsHidden()
            }
            if audio.stemMixEnabled && !audio.stemsAvailable {
                ProgressView("Separando faixas em segundo plano…")
                    .font(.caption)
            }
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 7) {
                ForEach(StemMixPreset.allCases) { preset in
                    Button(preset.title) { audio.applyStemPreset(preset) }
                        .font(.caption.weight(.semibold))
                        .accessibilityIdentifier("stem.preset.\(preset.id)")
                }
            }
            ForEach(StemKind.allCases) { kind in
                HStack(spacing: 8) {
                    Text(kind.title).font(.caption).frame(width: 88, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(audio.stemLevels[kind] ?? 1) },
                        set: { audio.setStemLevel(kind, level: Float($0)) }), in: 0...1)
                        .accessibilityIdentifier("stem.level.\(kind.rawValue)")
                }
            }
        }
        .accessibilityIdentifier("stem.mixer")
    }
}
