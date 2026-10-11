import SwiftUI

/// Shared overlay chrome stays reachable in Zen and clean karaoke.
struct EnvironmentBar: View {
    @Binding var theme: AppTheme
    let panels: [PanelID]

    var body: some View {
        HStack(spacing: 8) {
            PanelsMenuButton(panels: panels)
            ThemeBoltButton(theme: $theme)
        }
    }
}

extension View {
    func environmentButtonSurface() -> some View {
        frame(width: 44, height: 44)
            .background(Color.white.opacity(0.10), in: Circle())
            .contentShape(Circle())
    }
}

struct ThemeBoltButton: View {
    @Binding var theme: AppTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func select(_ next: AppTheme) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) { theme = next }
    }

    var body: some View {
        Button { select(theme.next) } label: {
            Image(systemName: "bolt.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(theme.accent)
                .environmentButtonSurface()
        }
        .buttonStyle(.plain)
        .contextMenu {
            ForEach(AppTheme.allCases) { option in
                Button { select(option) } label: {
                    Label("\(option.displayName) · \(option.dominantColorName)",
                          systemImage: option == theme ? "checkmark.circle.fill" : "circle")
                }
            }
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: theme)
        .accessibilityLabel("Trocar tema")
        .accessibilityValue("\(theme.displayName), \(theme.dominantColorName)")
        .accessibilityHint("Alterna entre os temas. Toque e segure para escolher um.")
    }
}
