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
    case omnibox, discover, queue, playback, presets, export

    static let mainPanels: [PanelID] = [.player, .omnibox, .discover, .queue, .playback, .presets, .controls, .export]
    static let karaokePanels: [PanelID] = [.player, .lyrics, .themes]
    // Telas novas: adicione um case + título + ícone aqui.

    var id: String { rawValue }
    var title: String {
        switch self {
        case .player: return "Player"
        case .lyrics: return "Letras"
        case .themes: return "Temas e fundo"
        case .controls: return "Controles"
        case .omnibox: return "Busca"
        case .discover: return "Descobrir"
        case .queue: return "A seguir"
        case .playback: return "Reprodução"
        case .presets: return "Presets"
        case .export: return "Exportar"
        }
    }
    var icon: String {
        switch self {
        case .player: return "music.note"
        case .lyrics: return "text.quote"
        case .themes: return "paintpalette"
        case .controls: return "slider.horizontal.3"
        case .omnibox: return "magnifyingglass"
        case .discover: return "sparkles"
        case .queue: return "list.dash"
        case .playback: return "waveform"
        case .presets: return "slider.horizontal.3"
        case .export: return "square.and.arrow.up"
        }
    }
}

/// Presets only edit the existing visibility preference, never accordion expansion.
enum PanelDensity: String, CaseIterable, Identifiable {
    case discover, balanced, listen
    var id: String { rawValue }
    var title: String {
        switch self {
        case .discover: return "Descobrir"
        case .balanced: return "Equilibrado"
        case .listen: return "Só ouvir"
        }
    }
    var visiblePanels: Set<PanelID> {
        switch self {
        case .discover: return Set(PanelID.allCases)
        case .balanced: return [.player, .omnibox, .queue, .lyrics, .themes]
        case .listen: return [.player, .controls, .lyrics, .themes]
        }
    }
}

/// Derived presentation: searching never writes visibility or expansion preferences.
enum PanelPresentation {
    static func showsDiscover(hidden: Set<PanelID>, isZen: Bool, searchActive: Bool) -> Bool {
        !isZen && (!hidden.contains(.discover) || (!hidden.contains(.omnibox) && searchActive))
    }

    static func discoverExpanded(saved: Bool, searchActive: Bool, userOverride: Bool?) -> Bool {
        searchActive ? (userOverride ?? true) : saved
    }
}

@MainActor
@Observable
final class PanelStore {
    static let motion: Animation = .smooth(duration: 0.45)

    private(set) var hidden: Set<PanelID>
    private(set) var isZen = false
    @ObservationIgnored private let defaultsKey = "ui.hiddenPanels"

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.stringArray(forKey: defaultsKey) ?? []
        var migrated = Set(raw.compactMap(PanelID.init(rawValue:)))
        let legacy: [(String, PanelID)] = [
            ("visibleDiscover", .discover), ("visibleQueue", .queue),
            ("visiblePlayback", .playback), ("visiblePresets", .presets),
            ("visibleControls", .controls), ("visibleExport", .export)
        ]
        for (key, id) in legacy where defaults.object(forKey: key) != nil {
            if !defaults.bool(forKey: key) { migrated.insert(id) }
        }
        hidden = migrated
        // Write the merged preference BEFORE removing its legacy source.
        persist()
        for (key, _) in legacy { defaults.removeObject(forKey: key) }
        // Zen is now a session-only mask on both screens.
        defaults.removeObject(forKey: "isZenMode")
    }

    func isVisible(_ id: PanelID) -> Bool { !isZen && !hidden.contains(id) }
    func isHidden(_ id: PanelID) -> Bool { hidden.contains(id) }

    func toggle(_ id: PanelID) { setVisible(isHidden(id), for: id) }

    func setVisible(_ visible: Bool, for id: PanelID) {
        withAnimation(Self.motion) {
            isZen = false
            if visible { hidden.remove(id) } else { hidden.insert(id) }
        }
        persist()
    }
    func showAll() { withAnimation(Self.motion) { isZen = false; hidden.removeAll() }; persist() }
    func apply(_ density: PanelDensity) {
        withAnimation(Self.motion) {
            isZen = false
            hidden = Set(PanelID.allCases).subtracting(density.visiblePanels)
        }
        persist()
    }
    func setZen(_ on: Bool) { withAnimation(Self.motion) { isZen = on } }
    func toggleZen() { setZen(!isZen) }

    private func persist() {
        defaults.set(hidden.map(\.rawValue).sorted(), forKey: defaultsKey)
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
            Button(store.isZen ? "Sair do modo Zen" : "Entrar no modo Zen", systemImage: "eye.slash") {
                store.toggleZen()
            }
            Section("Densidade da interface") {
                ForEach(PanelDensity.allCases) { density in
                    Button(density.title) { store.apply(density) }
                }
            }
            Section("Painéis desta tela") {
                ForEach(panels) { id in
                    Toggle(isOn: Binding(get: { !store.isHidden(id) }, set: { store.setVisible($0, for: id) })) {
                        Label(id.title, systemImage: id.icon)
                    }
                }
            }
            Button("Mostrar tudo", systemImage: "eye") { store.showAll() }
        } label: {
            Image(systemName: store.isZen ? "eye.slash.fill" : "eye")
                .font(.system(size: 18, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .environmentButtonSurface()
                .foregroundStyle(.white)
        } primaryAction: {
            store.toggleZen()
        }
        .accessibilityLabel("Visibilidade dos painéis")
        .accessibilityValue(store.isZen ? "Modo Zen ativado" : "Modo Zen desativado")
        .accessibilityAction(named: Text("Alternar modo Zen")) { store.toggleZen() }
        .accessibilityAction(named: Text("Mostrar tudo")) { store.showAll() }
        .accessibilityHint("Toque para ocultar ou mostrar tudo. Mantenha pressionado para escolher janelas.")
    }
}