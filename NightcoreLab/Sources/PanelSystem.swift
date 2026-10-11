import SwiftUI
import Observation

// =============================================================================
// Ocultar/exibir "janelas" sem mexer no visual delas.
//
//  • Cada painel ganha UMA linha:  .hideablePanel(.lyrics, edge: .bottom)
//  • Um botão de olho no canto: toque = modo Zen (esconde tudo e deixa só o fundo);
//    segurar = menu com um toggle por painel + "Mostrar tudo".
//  • Zen NÃO altera a escolha individual: ao sair, cada painel volta como estava.
//  • Nada de alças/badges nos painéis: a estética original fica intacta.
// =============================================================================

enum PanelID: String, CaseIterable, Identifiable {
    case player, lyrics, themes, controls
    // Telas novas: adicione um case + título + ícone aqui.

    var id: String { rawValue }
    var title: String {
        switch self {
        case .player: return "Player"
        case .lyrics: return "Letras"
        case .themes: return "Temas e fundo"
        case .controls: return "Controles"
        }
    }
    var icon: String {
        switch self {
        case .player: return "music.note"
        case .lyrics: return "text.quote"
        case .themes: return "paintpalette"
        case .controls: return "slider.horizontal.3"
        }
    }
}

@MainActor
@Observable
final class PanelStore {
    static let motion: Animation = .smooth(duration: 0.45)

    private(set) var hidden: Set<PanelID>
    private(set) var isZen = false
    @ObservationIgnored private let defaultsKey = "ui.hiddenPanels"

    init() {
        let raw = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        hidden = Set(raw.compactMap(PanelID.init(rawValue:)))
    }

    func isVisible(_ id: PanelID) -> Bool { !isZen && !hidden.contains(id) }
    func isHidden(_ id: PanelID) -> Bool { hidden.contains(id) }

    func toggle(_ id: PanelID) {
        withAnimation(Self.motion) {
            isZen = false
            if hidden.contains(id) { hidden.remove(id) } else { hidden.insert(id) }
        }
        persist()
    }
    func showAll() { withAnimation(Self.motion) { isZen = false; hidden.removeAll() }; persist() }
    func setZen(_ on: Bool) { withAnimation(Self.motion) { isZen = on } }
    func toggleZen() { setZen(!isZen) }

    private func persist() {
        UserDefaults.standard.set(hidden.map(\.rawValue), forKey: defaultsKey)
    }
}

// MARK: - Modificador + transição

extension View {
    /// `keepsSpace: true` mantém um Spacer no lugar quando oculto (use no painel central, p/ a barra
    /// inferior não "subir" colada no header).
    func hideablePanel(_ id: PanelID, edge: Edge = .bottom,
                       keepsSpace: Bool = false, enabled: Bool = true) -> some View {
        modifier(HideablePanel(id: id, edge: edge, keepsSpace: keepsSpace, enabled: enabled))
    }
}

private struct HideablePanel: ViewModifier {
    @Environment(PanelStore.self) private var panels
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let id: PanelID
    let edge: Edge
    let keepsSpace: Bool
    let enabled: Bool

    func body(content: Content) -> some View {
        if !enabled || panels.isVisible(id) {
            content.transition(reduceMotion ? .opacity : .panelHide(edge))
        } else if keepsSpace {
            Spacer(minLength: 0)
        }
    }
}

/// Some como "vapor": fade + blur + leve recuo em direção à própria borda.
private struct PanelHideEffect: ViewModifier {
    let amount: CGFloat            // 0 = visível · 1 = oculto
    let edge: Edge

    private var unit: CGSize {
        switch edge {
        case .top: return CGSize(width: 0, height: -1)
        case .bottom: return CGSize(width: 0, height: 1)
        case .leading: return CGSize(width: -1, height: 0)
        case .trailing: return CGSize(width: 1, height: 0)
        }
    }
    private var anchor: UnitPoint {
        switch edge {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }

    func body(content: Content) -> some View {
        content
            .opacity(1 - amount)
            .blur(radius: 14 * amount)
            .scaleEffect(1 - 0.05 * amount, anchor: anchor)
            .offset(x: unit.width * 24 * amount, y: unit.height * 24 * amount)
    }
}

extension AnyTransition {
    static func panelHide(_ edge: Edge) -> AnyTransition {
        .modifier(active: PanelHideEffect(amount: 1, edge: edge),
                  identity: PanelHideEffect(amount: 0, edge: edge))
    }
}

// MARK: - Botão de olho (toque = Zen · segurar = menu por painel)

struct PanelsMenuButton: View {
    let panels: [PanelID]                       // só os painéis que existem na tela atual
    @Environment(PanelStore.self) private var store

    var body: some View {
        Menu {
            Section("Janelas") {
                ForEach(panels) { id in
                    Toggle(isOn: Binding(get: { !store.isHidden(id) }, set: { _ in store.toggle(id) })) {
                        Label(id.title, systemImage: id.icon)
                    }
                }
            }
            Button("Mostrar tudo", systemImage: "eye") { store.showAll() }
        } label: {
            Image(systemName: store.isZen ? "eye.slash.fill" : "eye")
                .font(.system(size: 18, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.10), in: Circle())
                .foregroundStyle(.white)
        } primaryAction: {
            store.toggleZen()
        }
        .accessibilityLabel(store.isZen ? "Mostrar janelas" : "Ocultar janelas")
        .accessibilityHint("Toque para ocultar ou mostrar tudo. Mantenha pressionado para escolher janelas.")
    }
}