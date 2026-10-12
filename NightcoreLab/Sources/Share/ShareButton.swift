import SwiftUI

/// The still card remains available; videos use the same share entry point.
struct ShareButton: View {
    let isWorking: Bool
    let canExportLyrics: Bool
    @Binding var typography: TypographyFont
    let onImage: () -> Void
    let onVideo: (StoryMode, Bool) -> Void

    var body: some View {
        Menu {
            Button { onImage() } label: {
                Label("Imagem estática", systemImage: "photo")
            }
            Section("Vídeo · Story de até 15 s") {
                Button { onVideo(.player, true) } label: {
                    Label("Player com áudio", systemImage: "play.rectangle")
                }
                Button { onVideo(.lyrics, true) } label: {
                    Label("Letras com áudio", systemImage: "text.bubble")
                }
                .disabled(!canExportLyrics)
                Button { onVideo(.player, false) } label: {
                    Label("Player sem áudio", systemImage: "speaker.slash")
                }
                Button { onVideo(.lyrics, false) } label: {
                    Label("Letras sem áudio", systemImage: "text.quote")
                }
                .disabled(!canExportLyrics)
            }
            // Same font axis as the live karaoke (TypographyFont).
            Section("Fonte das letras") {
                Picker("Tipografia", selection: $typography) {
                    ForEach(TypographyFont.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            }
        } label: {
            Group {
                if isWorking {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                }
            }
            .frame(width: 44, height: 44)
            .background(Color.white.opacity(0.10), in: Circle())
            .foregroundStyle(.white)
        }
        .disabled(isWorking)
        .accessibilityLabel("Compartilhar imagem ou vídeo da música atual")
        .accessibilityHint("Escolha a imagem ou um Story em vídeo do player ou das letras.")
    }
}
