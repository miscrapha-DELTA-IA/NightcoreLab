import Foundation

/// Presentation-only taxonomy. Persisted AppTheme raw values and existing
/// CreativePreset IDs remain untouched for old installations and exports.
enum CreativeVisualTaxonomy {
    static let materialThemes: [AppTheme] = [
        .xeroxSerpentine, .prismCarmine, .subatomicBubble,
        .jacquardSignal, .isometricChasm, .lenticularWild
    ]
    static let gnarlyModes: [AppTheme] = [
        .gnarly, .gnarlyStrata, .gnarlyCompiler, .gnarlyOrganism
    ]
    static let classicThemes: [AppTheme] = AppTheme.allCases.filter {
        !materialThemes.contains($0) && !gnarlyModes.contains($0)
    }
    static let selectableThemes: [AppTheme] = classicThemes + materialThemes

    static func nextTheme(after current: AppTheme) -> AppTheme {
        guard let index = selectableThemes.firstIndex(of: current) else {
            return selectableThemes[0]
        }
        return selectableThemes[(index + 1) % selectableThemes.count]
    }

    static let roleExplanation =
        "Tema = identidade e material. Experiência = comportamento visual. " +
        "Ritmo visual = força da reação ao áudio. Modo GNARLY = " +
        "universo autônomo que evolui ao longo da música."
}
