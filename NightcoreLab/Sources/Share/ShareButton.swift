import SwiftUI

/// UI only: no knowledge of playback, Metal or exporting.
struct ShareButton: View {
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
        .buttonStyle(.plain)
        .disabled(isWorking)
        .accessibilityLabel("Compartilhar a música atual")
        .accessibilityHint("Cria uma imagem com a capa e o tema do player")
        .accessibilityAddTraits(isWorking ? [] : .isButton)
    }
}
