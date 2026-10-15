import SwiftUI

/// Discovery presentation only. Playback and the player visibility live elsewhere.
struct SearchDrawerState: Equatable {
    private(set) var isOpen = false
    private(set) var focusRequest = 0
    private(set) var pendingTrackID: String?

    mutating func toggle() { isOpen.toggle() }
    mutating func close() { isOpen = false }
    mutating func openForSearch() {
        isOpen = true
        focusRequest += 1
    }

    mutating func selectedTrack() { close() }
    mutating func beginSelection(trackID: String) { pendingTrackID = trackID }
    @discardableResult
    mutating func confirmPlayback(trackID: String) -> Bool {
        guard pendingTrackID == trackID else { return false }
        pendingTrackID = nil
        selectedTrack()
        return true
    }
    @discardableResult
    mutating func selectionFailed(trackID: String) -> Bool {
        guard pendingTrackID == trackID else { return false }
        pendingTrackID = nil
        return true
    }
}

enum DrawerQuickAccess {
    static func shouldShow(query: String, submittedQuery: String?) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && submittedQuery == nil
    }
    static func recents(recent: [Track], cached: [Track], current: Track?) -> [Track] {
        var seen = Set<String>()
        return (recent + cached + [current].compactMap { $0 })
            .filter { seen.insert($0.id).inserted }
            .prefix(8).map { $0 }
    }
}

enum DrawerHubTab: String, CaseIterable {
    case mix, offline, queue, albumArtist
}

/// Local, deterministic fallback: no network request is needed to open the drawer.
/// History and downloaded tracks always rank above these official catalog entries.
enum DrawerSmartMix {
    private static let catalog: [(String, String, String)] = [
        ("4NRXx6U8ABQ", "Blinding Lights", "The Weeknd"),
        ("JGwWNGJdvx8", "Shape of You", "Ed Sheeran"),
        ("hT_nvWreIhg", "Counting Stars", "OneRepublic"),
        ("fRh_vgS2dFE", "Sorry", "Justin Bieber"),
        ("RgKAFK5djSk", "See You Again", "Wiz Khalifa"),
        ("2Vv-BfVoq4g", "Perfect", "Ed Sheeran"),
        ("OPf0YbXqDm0", "Uptown Funk", "Mark Ronson"),
        ("CevxZvSJLk8", "Roar", "Katy Perry"),
        ("kJQP7kiw5Fk", "Despacito", "Luis Fonsi"),
        ("YQHsXMglC9A", "Hello", "Adele"),
        ("60ItHLz5WEA", "Faded", "Alan Walker"),
        ("pRpeEdMmmQ0", "Waka Waka", "Shakira"),
        ("ktvTqknDobU", "Radioactive", "Imagine Dragons"),
        ("e-ORhEE9VVg", "Blank Space", "Taylor Swift"),
        ("TjfbYH7ab-c", "Flowers", "Miley Cyrus")
    ]

    static func resolve(history: [HistoryEntry], cached: [Track],
                        discovery: [Track], current: Track?) -> [Track] {
        let ranked = history.sorted {
            let lhs = Double($0.plays + 2 * ($0.completions ?? 0) - 2 * ($0.earlySkips ?? 0))
            let rhs = Double($1.plays + 2 * ($1.completions ?? 0) - 2 * ($1.earlySkips ?? 0))
            if lhs != rhs { return lhs > rhs }
            if $0.lastPlayed != $1.lastPlayed { return $0.lastPlayed > $1.lastPlayed }
            return $0.hit.id < $1.hit.id
        }.map { $0.hit.asTrack }
        let fallback = catalog.map { item -> Track in
            let (id, title, artist) = item
            var track = Track(id: id, title: title,
                thumbnailURL: URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"))
            track.cleanArtist = artist
            track.cleanTitle = title
            return track
        }
        var seen = Set<String>()
        return Array((ranked + cached + [current].compactMap { $0 } + discovery + fallback)
            .filter { seen.insert($0.id).inserted }.prefix(15))
    }
}
import Observation

// =============================================================================
// Ocultar/exibir "janelas" sem mexer no visual delas.
//
//  • Cada painel ganha UMA linha:  .hideablePanel(.lyrics, edge: .bottom)
//  • O olho abre um popover persistente: alternar vários painéis sem sair.
//  • O editor oferece layouts rápidos, grupos e toggles individuais.
//  • Zen NÃO altera a escolha individual: ao sair, cada painel volta como estava.
//  • Nada de alças/badges nos painéis: a estética original fica intacta.
// =============================================================================

enum PanelID: String, CaseIterable, Identifiable {
    case header, player, lyrics, themes, controls
    case omnibox, discover, queue, presets, export

    static let discoveryPanels: [PanelID] = [.omnibox, .discover, .queue]
    static let audioPanels: [PanelID] = [.presets, .controls]
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
        case .listen: return [.player, .presets, .controls, .lyrics, .themes]
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
        setVisible(visible, for: [id])
    }

    /// Batch updates are atomic: one animation and one saved preference per tap.
    func setVisible(_ visible: Bool, for ids: [PanelID]) {
        withAnimation(Self.motion) {
            isZen = false
            if visible { hidden.subtract(ids) } else { hidden.formUnion(ids) }
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

// MARK: - Editor persistente de visibilidade

struct PanelsMenuButton: View {
    let panels: [PanelID]
    @Environment(PanelStore.self) private var store
    @State private var isEditorPresented = false

    var body: some View {
        Button {
            isEditorPresented = true
        } label: {
            Image(systemName: store.isZen ? "eye.slash.fill" : "eye")
                .font(.system(size: 18, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .environmentButtonSurface()
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isEditorPresented, arrowEdge: .top) {
            PanelVisibilityEditor(panels: panels)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("Gerenciar painéis")
        .accessibilityValue(store.isZen ? "Modo Zen ativado" : "Modo Zen desativado")
        .accessibilityAction(named: Text("Alternar modo Zen")) { store.toggleZen() }
        .accessibilityAction(named: Text("Mostrar tudo")) { store.showAll() }
        .accessibilityHint("Abre o editor. Alterne várias janelas sem fechar o painel.")
    }
}

/// Unlike a Menu, a popover does not dismiss after every switch or preset.
private struct PanelVisibilityEditor: View {
    let panels: [PanelID]
    @Environment(PanelStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var discoveryIDs: [PanelID] {
        PanelID.discoveryPanels.filter { panels.contains($0) }
    }
    private var audioIDs: [PanelID] {
        PanelID.audioPanels.filter { panels.contains($0) }
    }
    private var otherIDs: [PanelID] {
        panels.filter {
            !PanelID.discoveryPanels.contains($0) && !PanelID.audioPanels.contains($0)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Exibição", systemImage: "eye")
                        .font(.headline)
                    Spacer()
                    Button("Concluído") { dismiss() }
                        .font(.subheadline.weight(.semibold))
                }

                Text("Escolha quantos painéis quiser. Este editor permanece aberto.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 9) {
                    Text("LAYOUTS RÁPIDOS")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        quickLayout("Tudo", symbol: "eye") { store.showAll() }
                        quickLayout("Essencial", symbol: "square.grid.2x2") { store.apply(.balanced) }
                        quickLayout("Só ouvir", symbol: "headphones") { store.apply(.listen) }
                    }
                    Button {
                        store.toggleZen()
                    } label: {
                        Label(store.isZen ? "Sair do Zen" : "Fundo livre (Zen)",
                              systemImage: "eye.slash")
                    }
                    .font(.subheadline)
                    .buttonStyle(.plain)
                }
                Divider()

                if !discoveryIDs.isEmpty {
                    HStack {
                        Text("MÚSICAS · BUSCA E DESCOBERTA")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("Tudo") { store.setVisible(true, for: discoveryIDs) }
                            .font(.caption.weight(.semibold))
                        Button("Nada") { store.setVisible(false, for: discoveryIDs) }
                            .font(.caption.weight(.semibold))
                    }
                    ForEach(discoveryIDs) { id in panelToggle(id) }
                    Divider()
                }

                if !audioIDs.isEmpty {
                    HStack {
                        Text("ÁUDIO · PRESETS E CONTROLES")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("Tudo") { store.setVisible(true, for: audioIDs) }
                            .font(.caption.weight(.semibold))
                        Button("Nada") { store.setVisible(false, for: audioIDs) }
                            .font(.caption.weight(.semibold))
                    }
                    ForEach(audioIDs) { id in panelToggle(id) }
                    Divider()
                }

                if !otherIDs.isEmpty {
                    Text("OUTRAS JANELAS")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.secondary)
                    ForEach(otherIDs) { id in panelToggle(id) }
                }

                Button {
                    store.hideAll(in: panels)
                } label: {
                    Label("Ocultar janelas desta tela", systemImage: "rectangle.slash")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
            }
            .padding(18)
        }
        .frame(width: 330, height: 480)
        .tint(.primary)
    }

    private func quickLayout(_ title: String, symbol: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                Text(title).font(.caption2.weight(.semibold)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func panelToggle(_ id: PanelID) -> some View {
        Toggle(isOn: Binding(
            get: { !store.isHidden(id) },
            set: { store.setVisible($0, for: id) }
        )) {
            Label(id.title, systemImage: id.icon)
                .font(.subheadline)
        }
        .toggleStyle(.switch)
    }
}
