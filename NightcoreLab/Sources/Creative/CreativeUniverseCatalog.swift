import Foundation
import SwiftUI
import UIKit

/// Stage 65: a single render vocabulary for live playback and Story GPU export.
/// The original Gnarly theme and all existing preset IDs retain their legacy
/// meanings; new IDs are deliberately prefixed so saved user packages survive.
enum CreativeUniverseCatalog {
    struct Entry: Equatable, Sendable {
        let id: Int
        let slug: String
        let name: String
        let category: String
        let references: String
        let palette: [String]
    }

    static let entries: [Entry] = [
        .init(id: 1, slug: "xerox-serpentine", name: "Xerox Serpentine", category: "theme", references: "IMG-04,21,13", palette: ["#0D0D0E","#F2F0E6","#F7EE18"]),
        .init(id: 2, slug: "prism-carmine", name: "Prism Carmine", category: "theme", references: "IMG-22,16,14", palette: ["#38000C","#FF0D38","#79E5F2"]),
        .init(id: 3, slug: "subatomic-bubble", name: "Subatomic Bubble", category: "theme", references: "IMG-01,08,19", palette: ["#0A2246","#F5B82E","#3895D3"]),
        .init(id: 4, slug: "jacquard-signal", name: "Jacquard Signal", category: "theme", references: "IMG-05,13,24", palette: ["#0F0814","#B5944B","#521296"]),
        .init(id: 5, slug: "isometric-chasm", name: "Isometric Chasm", category: "theme", references: "IMG-25,06,17", palette: ["#020208","#0A19D6","#FFFFFF"]),
        .init(id: 6, slug: "lenticular-wild", name: "Lenticular Wild", category: "theme", references: "IMG-24,12,21", palette: ["#0A0909","#CF9B48","#F4EEDF"]),
        .init(id: 7, slug: "subcultural-archive", name: "Subcultural Archive", category: "experience", references: "IMG-04,13,21", palette: ["#151413","#F0EFEA","#F6EB14"]),
        .init(id: 8, slug: "caustic-dissection", name: "Caustic Dissection", category: "experience", references: "IMG-22,14,26", palette: ["#38000C","#FF0D38","#E3E8EC"]),
        .init(id: 9, slug: "tectonic-mesh", name: "The Tectonic Mesh", category: "experience", references: "IMG-18,05", palette: ["#242428","#A312FF","#B5944B"]),
        .init(id: 10, slug: "vector-drift-2000", name: "Vector Drift 2000", category: "experience", references: "IMG-08,15,20", palette: ["#060B0A","#6B9E38","#F3FFE3"]),
        .init(id: 11, slug: "liquid-monochrome", name: "The Liquid Monochrome", category: "experience", references: "IMG-02,23,26", palette: ["#12080C","#DCDCDC","#FF0040"]),
        .init(id: 12, slug: "nocturnal-lithograph", name: "Nocturnal Lithograph", category: "experience", references: "IMG-07,17,19", palette: ["#08080A","#C8BFA3","#1F6A4E"]),
        .init(id: 13, slug: "metamorphic-strata", name: "Metamorphic Strata", category: "procedural", references: "IMG-06,18,25", palette: ["#141820","#0A19D6","#D1A960"]),
        .init(id: 14, slug: "kinematic-compiler", name: "Kinematic Compiler", category: "procedural", references: "IMG-01,08,20", palette: ["#030609","#68ECEA","#F5B82E"]),
        .init(id: 15, slug: "chromatic-organism", name: "Chromatic Organism", category: "procedural", references: "IMG-02,03,23,26", palette: ["#080608","#FF6BA5","#62C3D0"])
    ]

    static let experiences: [Entry] = entries.filter { $0.category == "experience" }

    /// User-facing role vocabulary. No change to IDs, serialized packages,
    /// render topology, or existing preset lookup contracts.
    static func experienceDescription(slug: String) -> String {
        switch slug {
        case "subcultural-archive":
            return "Colagem de zine, retículas e golpes gráficos guiados pela bateria."
        case "caustic-dissection":
            return "Cristais refratam e se fragmentam ao ritmo da música."
        case "tectonic-mesh":
            return "Falhas geológicas e filamentos sob tensão reativa."
        case "vector-drift-2000":
            return "Travessia de um túnel em perspectiva, acelerado por graves."
        case "liquid-monochrome":
            return "Convecção de esmalte e células que se abrem com os graves."
        case "nocturnal-lithograph":
            return "Gravura noturna com interferências, oxidação e ondas."
        default:
            return "Experiência audiovisual de transformação."
        }
    }


    static func lookID(theme: MarbleTheme, materialID: String) -> Int? {
        // Modes are standalone systems, not color skins. A previously chosen
        // experience stays saved but cannot silently replace Gnarly mode.
        // The original .gnarly is handled by GnarlyThemeEngine upstream.
        switch theme {
        case .gnarly, .gnarlyStrata, .gnarlyCompiler, .gnarlyOrganism:
            switch theme {
            case .gnarlyStrata: return 13
            case .gnarlyCompiler: return 14
            case .gnarlyOrganism: return 15
            default: return nil
            }
        default: break
        }
        // For ordinary themes, experience supplies the composition and the
        // theme affects its palette/material geometry without a duplicate ID.
        if materialID.hasPrefix("gnarly-exp-"),
           let entry = experiences.first(where: { "gnarly-exp-" + $0.slug == materialID }) {
            return entry.id
        }
        switch theme {
        case .xeroxSerpentine: return 1
        case .prismCarmine: return 2
        case .subatomicBubble: return 3
        case .jacquardSignal: return 4
        case .isometricChasm: return 5
        case .lenticularWild: return 6
        case .gnarlyStrata: return 13
        case .gnarlyCompiler: return 14
        case .gnarlyOrganism: return 15
        default: return nil
        }
    }

    /// Uses the already-cached artwork hue; no network or bitmap processing
    /// occurs on the display link. On procedural modes the first 20% of the
    /// song stays cover-inspired and blends out gradually by 28%.
    /// Stable conversion performed only once per theme. The 6 experiences
    /// retain their authored behavior; the user's theme supplies meaningful
    /// material contrast and highlight direction instead of a token accent.
    /// The shader reads these tones to modify geometry without a new uniform.
    private static let themeTints: [MarbleTheme: [GnarlyThemeEngine.RGB]] = {
        Dictionary(uniqueKeysWithValues: MarbleTheme.allCases.map { theme in
            let palette = theme.palette
            let stops: [Color] = [palette.deep, palette.body, palette.glow]
            return (theme, stops.map { color in
                var r: CGFloat = 0
                var g: CGFloat = 0
                var b: CGFloat = 0
                var a: CGFloat = 0
                UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
                return GnarlyThemeEngine.RGB(
                    red: Double(r), green: Double(g), blue: Double(b))
            })
        })
    }()

    static func palette(id: Int, sourceTime: TimeInterval,
                        duration: TimeInterval, artworkHue: Double?,
                        theme: MarbleTheme? = nil) -> [Color] {
        guard let entry = entries.first(where: { $0.id == id }) else {
            return [Color.black, Color.gray, Color.white]
        }
        let authored = entry.palette.map(GnarlyThemeEngine.RGB.hex)
        if (7...12).contains(id), let theme, let tint = themeTints[theme] {
            return [
                GnarlyThemeEngine.RGB.mix(authored[0], tint[0], 0.46).color,
                GnarlyThemeEngine.RGB.mix(authored[1], tint[1], 0.67).color,
                GnarlyThemeEngine.RGB.mix(authored[2], tint[2], 0.78).color
            ]
        }
        guard id >= 13, let hue = artworkHue, hue.isFinite,
              duration.isFinite, duration > 0 else {
            return authored.map(\.color)
        }
        let position = min(1, max(0, sourceTime / duration))
        let x = min(1, max(0, (position - 0.2) / 0.08))
        let blend = x * x * (3 - 2 * x)
        let cover = [
            GnarlyThemeEngine.RGB.hsv(hue, saturation: 0.65, brightness: 0.06),
            GnarlyThemeEngine.RGB.hsv(hue + 0.025, saturation: 0.82, brightness: 0.78),
            GnarlyThemeEngine.RGB.hsv(hue - 0.025, saturation: 0.47, brightness: 0.94)
        ]
        return zip(cover, authored).map {
            GnarlyThemeEngine.RGB.mix($0.0, $0.1, blend).color
        }
    }

    static func material(for entry: Entry) -> VisualMaterial {
        VisualMaterial(
            id: "gnarly-exp-" + entry.slug, name: entry.name,
            parameters: .init(beatPulse: 0.48, pulseDecay: 6,
                              warpAmount: 0.19, brightnessBoost: 0.09),
            audioMapping: .init(bassToDistortion: 0.14,
                                energyToBrightness: 0.06,
                                beatToPulse: 0.65))
    }
}
