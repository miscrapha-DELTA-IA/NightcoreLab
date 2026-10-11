import SwiftUI
import Observation

// =============================================================================
// Ocultar/exibir "janelas" sem mexer no visual delas.
//
//  • Cada painel ganha UMA linha:  .hideablePanel(.lyrics, edge: .bottom)
//  • Um botão de olho no canto abre o menu com um toque simples.
//  • O menu oferece "Mostrar tudo", modo Zen e toggles por painel.
//  • Zen NÃO altera a escolha individual: ao sair, cada painel volta como estava.
//  • Nada de alças/badges nos painéis: a estética original fica intacta.
// =============================================================================

enum PanelID: String, CaseIterable, Identifiable {
    case header, player, lyrics, themes, controls
    case omnibox, discover, queue, presets, export

    static let mainPanels: [PanelID] = [.header, .player, .omnibox, .discover, .queue, .presets, .controls, .export]
    static let karaokePanels: [PanelID] = [.player, .lyrics, .themes]
    // Telas novas: adicione um case + título + ícone aqui.

    var id: String { rawValue }
    var title: String {
        switch self {
        case .header: return "Cabeçalho e atalhos"
        case .player: return "Player"
        case .lyrics: return "Letras"
        case .themes: return "Temas e fundo"
        case .controls: return "Controles"
        case .omnibox: return "Busca"
        case .discover: return "Descobrir"
        case .queue: return "A seguir"
        case .presets: return "Presets"
        case .export: return "Exportar"
        }
    }
    var icon: String {
        switch self {
        case .header: return "heart.text.square"
        case .player: return "music.note"
        case .lyrics: return "text.quote"
        case .themes: return "paintpalette"
        case .controls: return "slider.horizontal.3"
        case .omnibox: return "magnifyingglass"
        case .discover: return "sparkles"
        case .queue: return "list.dash"
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
        case .discover: return "Completo"
        case .balanced: return "Essencial"
        case .listen: return "Só ouvir"
        }
    }
    var visiblePanels: Set<PanelID> {
        switch self {
        case .discover: return Set(PanelID.allCases)
        case .balanced: return [.header, .player, .omnibox, .discover, .queue, .controls, .lyrics, .themes]
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
            ("visiblePresets", .presets),
            ("visibleControls", .controls), ("visibleExport", .export)
        ]
        for (key, id) in legacy where defaults.object(forKey: key) != nil {
            if !defaults.bool(forKey: key) { migrated.insert(id) }
        }
        hidden = migrated
        // Write the merged preference BEFORE removing its legacy source.
        persist()
        for (key, _) in legacy { defaults.removeObject(forKey: key) }
        // The former Reprodução accordion was merged into Player: drop its old visibility key.
        defaults.removeObject(forKey: "visiblePlayback")
        // Zen is now a session-only mask on both screens.
        defaults.removeObject(forKey: "isZenMode")
    }

    func isVisible(_ id: PanelID) -> Bool { !isZen && !hidden.contains(id) }
    func isHidden(_ id: PanelID) -> Bool { hidden.contains(id) }

    /// Visible recovery affordance counts only the panels relevant to this screen.
    func hiddenCount(in ids: [PanelID]) -> Int {
        ids.filter { hidden.contains($0) }.count
    }

    func toggle(_ id: PanelID) { setVisible(isHidden(id), for: id) }

    func setVisible(_ visible: Bool, for id: PanelID) {
        withAnimation(Self.motion) {
            isZen = false
            if visible { hidden.remove(id) } else { hidden.insert(id) }
        }
        persist()
    }
    func showAll() { withAnimation(Self.motion) { isZen = false; hidden.removeAll() }; persist() }
    /// Hide the current screen's panels in one action; the eye menu remains outside this mask.
    func hideAll(in ids: [PanelID]) {
        withAnimation(Self.motion) {
            isZen = false
            hidden.formUnion(ids)
        }
        persist()
    }
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

// MARK: - Botão de olho (toque = menu de painéis e restauração)

struct PanelsMenuButton: View {
    let panels: [PanelID]                       // só os painéis que existem na tela atual
    @Environment(PanelStore.self) private var store

    var body: some View {
        Menu {
            Section("Layouts em um toque") {
                Button("Mostrar tudo", systemImage: "eye") { store.showAll() }
                Button("Essencial", systemImage: "square.grid.2x2") { store.apply(.balanced) }
                Button("Só ouvir", systemImage: "headphones") { store.apply(.listen) }
                Button("Ocultar seções desta tela", systemImage: "rectangle.slash") {
                    store.hideAll(in: panels)
                }
                Button(store.isZen ? "Sair do modo Zen" : "Fundo livre (Zen)",
                       systemImage: "eye.slash") { store.toggleZen() }
            }
            Section("Personalizar painéis") {
                ForEach(panels) { id in
                    Toggle(isOn: Binding(get: { !store.isHidden(id) }, set: { store.setVisible($0, for: id) })) {
                        Label(id.title, systemImage: id.icon)
                    }
                }
            }
        } label: {
            Image(systemName: store.isZen ? "eye.slash.fill" : "eye")
                .font(.system(size: 18, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .environmentButtonSurface()
                .foregroundStyle(.white)
        }
        .accessibilityLabel("Gerenciar painéis")
        .accessibilityValue(store.isZen ? "Modo Zen ativado" : "Modo Zen desativado")
        .accessibilityAction(named: Text("Alternar modo Zen")) { store.toggleZen() }
        .accessibilityAction(named: Text("Mostrar tudo")) { store.showAll() }
        .accessibilityHint("Toque para abrir o menu, mostrar painéis ocultos ou escolher o modo Zen.")
    }
}