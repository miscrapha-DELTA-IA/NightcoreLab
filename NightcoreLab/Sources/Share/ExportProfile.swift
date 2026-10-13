import Foundation
import CoreGraphics

/// Product choices ABOVE the legacy encoder. Defaults freeze the current
/// StoryEncodingProfile.recommended() selection made when the draft is opened.
enum ExportAspectRatio: String, Codable, CaseIterable, Identifiable, Sendable {
    case portrait, square, landscape
    var id: String { rawValue }
    var label: String {
        switch self {
        case .portrait: return "Vertical · 9:16"
        case .square: return "Quadrado · 1:1"
        case .landscape: return "Horizontal · 16:9"
        }
    }
}

enum ExportQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case economy, balanced, high
    var id: String { rawValue }
    var label: String {
        switch self {
        case .economy: return "Econômico"
        case .balanced: return "Equilibrado"
        case .high: return "Alta qualidade"
        }
    }
}

/// Only cropping is allowed to remove portrait content. Lyrics always use
/// the preserving policy: their placement is authored for a 540x960 canvas.
enum ExportCropPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case centerCrop, aspectFit, safeAreaPreserving
    var id: String { rawValue }
    var label: String {
        switch self {
        case .centerCrop: return "Corte central (pode cortar a capa)"
        case .aspectFit: return "Enquadrar completo · preto"
        case .safeAreaPreserving: return "Preservar conteúdo · tema"
        }
    }

    func resolved(for mode: StoryMode) -> Self {
        if mode == .lyrics && self == .centerCrop { return .safeAreaPreserving }
        return self
    }
}

struct ExportProfile: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    var aspectRatio: ExportAspectRatio = .portrait
    var quality: ExportQuality = .balanced
    var cropPolicy: ExportCropPolicy = .safeAreaPreserving

    static func matching(_ legacy: StoryEncodingProfile) -> Self {
        ExportProfile(
            aspectRatio: .portrait,
            quality: legacy.width == StoryEncodingProfile.economical.width &&
                legacy.fps == StoryEncodingProfile.economical.fps ? .economy : .balanced,
            cropPolicy: .safeAreaPreserving)
    }

    /// Single mapping table. All outputs use H.264/MP4 through StoryPixelWriter.
    /// The original portrait Balanced/Economy values are intentionally identical.
    func encodingProfile(for mode: StoryMode) -> StoryEncodingProfile {
        let size: (Int, Int)
        switch (quality, aspectRatio) {
        case (.economy, .portrait): size = (540, 960)
        case (.economy, .square): size = (540, 540)
        case (.economy, .landscape): size = (960, 540)
        case (.balanced, .portrait): size = (720, 1280)
        case (.balanced, .square): size = (720, 720)
        case (.balanced, .landscape): size = (1280, 720)
        case (.high, .portrait): size = (1080, 1920)
        case (.high, .square): size = (1080, 1080)
        case (.high, .landscape): size = (1920, 1080)
        }
        let fps: Int32 = quality == .economy ? 15 : (quality == .balanced ? 20 : 30)
        let bitRate = quality == .economy ? 1_600_000 :
            (quality == .balanced ? 2_800_000 : 5_500_000)
        return StoryEncodingProfile(width: size.0, height: size.1,
                                    fps: fps, bitRate: bitRate,
                                    cropPolicy: cropPolicy.resolved(for: mode))
    }
}
