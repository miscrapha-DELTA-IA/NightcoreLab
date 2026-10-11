import SwiftUI

/// Reusable, state-driven glass accordion. The caller owns/persists the Binding.
/// Content is removed from the view hierarchy when collapsed; search/download
/// state stays in its owning view so closing a panel never cancels playback.
struct CollapsibleGlassSection<Content: View>: View {
    let title: String
    let icon: String
    @Binding var isExpanded: Bool
    var tint: Color = .white
    var detail: String? = nil
    var integrated: Bool = false
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if integrated {
                HStack(spacing: 9) {
                    Image(systemName: icon)
                    Text(title.uppercased())
                        .font(.caption.bold())
                        .tracking(1.3)
                    Spacer(minLength: 8)
                    if let detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.60))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: 30)
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            } else {
                Button {
                    withAnimation(reduceMotion
                        ? .easeInOut(duration: 0.2)
                        : .spring(response: 0.4, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 9) {
                    Image(systemName: icon)
                    Text(title.uppercased())
                        .font(.caption.bold())
                        .tracking(1.3)
                    Spacer(minLength: 8)
                    if let detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.60))
                            .lineLimit(1)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                        .contentTransition(.symbolEffect(.replace))
                }
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expandido" : "Recolhido")
            .accessibilityHint(isExpanded ? "Toque para recolher" : "Toque para expandir")

                if isExpanded {
                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 12)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(integrated ? 0 : 14)
        .background {
            if !integrated {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        .overlay {
            if !integrated {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}
