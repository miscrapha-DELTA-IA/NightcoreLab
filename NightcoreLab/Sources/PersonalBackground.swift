import Foundation
import ImageIO
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// All coordinates are normalized to the view size to keep live/Story matching.
struct PersonalBackgroundSettings: Codable, Equatable, Sendable {
    var enabled = false
    var scale = 1.0
    var offsetX = 0.0
    var offsetY = 0.0
    var dimming = 0.38

    var normalized: Self {
        var copy = self
        copy.scale = copy.scale.isFinite ? min(2, max(1, copy.scale)) : 1
        copy.offsetX = copy.offsetX.isFinite ? min(0.5, max(-0.5, copy.offsetX)) : 0
        copy.offsetY = copy.offsetY.isFinite ? min(0.5, max(-0.5, copy.offsetY)) : 0
        copy.dimming = copy.dimming.isFinite ? min(0.75, max(0.15, copy.dimming)) : 0.38
        return copy
    }
}

/// Sendable, immutable image bytes: snapshots survive deletion/replacement
/// while an existing Story preview/export is running.
struct PersonalBackgroundSnapshot: Sendable {
    let id: UUID
    let imageData: Data
    let settings: PersonalBackgroundSettings
}

/// A bounded decoded cache shared by every Story frame, never a decode per frame.
@MainActor
enum PersonalBackgroundRenderCache {
    private static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 2
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    static func image(for snapshot: PersonalBackgroundSnapshot) -> UIImage? {
        let key = snapshot.id.uuidString as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let decoded = UIImage(data: snapshot.imageData) else { return nil }
        images.setObject(decoded, forKey: key,
                         cost: Int(decoded.size.width * decoded.size.height * 4))
        return decoded
    }

    static func clear() { images.removeAllObjects() }
}

/// Stable static background. No TimelineView, shader, animation, network, or
/// image decoding is performed while rendering its body.
struct PersonalBackgroundImageView: View {
    let image: UIImage
    let settings: PersonalBackgroundSettings

    var body: some View {
        GeometryReader { geometry in
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(settings.normalized.scale)
                .offset(x: geometry.size.width * settings.normalized.offsetX,
                        y: geometry.size.height * settings.normalized.offsetY)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .overlay(Color.black.opacity(settings.normalized.dimming))
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// User-owned photo is copied as a downsampled, metadata-free JPEG in the app
/// sandbox, never uploaded. Original Photos asset is never edited or removed.
@MainActor @Observable
final class PersonalBackgroundStore {
    private static let settingsKey = "gnarly.personal-background.v1"
    private static let uuidKey = "gnarly.personal-background.image-id.v1"
    private static let filename = "personal-background.jpg"
    private static func fileURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("GnarlyBackgrounds", isDirectory: true)
            .appendingPathComponent(filename)
    }

    private(set) var settings: PersonalBackgroundSettings
    private(set) var snapshot: PersonalBackgroundSnapshot?
    var errorMessage: String?
    var isImporting = false

    init() {
        let previous = UserDefaults.standard.data(forKey: Self.settingsKey)
        let current = previous.flatMap { try? JSONDecoder().decode(PersonalBackgroundSettings.self, from: $0) } ?? .init()
        let id = UserDefaults.standard.string(forKey: Self.uuidKey).flatMap(UUID.init(uuidString:)) ?? UUID()
        let data = try? Data(contentsOf: Self.fileURL(), options: .mappedIfSafe)
        settings = current.normalized
        if let data, !data.isEmpty {
            snapshot = .init(id: id, imageData: data, settings: settings)
        } else {
            settings.enabled = false
        }
    }

    var activeSnapshot: PersonalBackgroundSnapshot? {
        guard settings.enabled else { return nil }
        return snapshot
    }
    var activeImage: UIImage? {
        activeSnapshot.flatMap { PersonalBackgroundRenderCache.image(for: $0) }
    }

    func enable() {
        guard snapshot != nil else { return }
        update { $0.enabled = true }
    }
    func disable() { update { $0.enabled = false } }

    func update(_ edit: (inout PersonalBackgroundSettings) -> Void) {
        var value = settings
        edit(&value)
        settings = value.normalized
        if let previous = snapshot {
            snapshot = .init(id: previous.id, imageData: previous.imageData, settings: settings)
        }
        persist()
    }

    func remove() {
        settings.enabled = false
        snapshot = nil
        PersonalBackgroundRenderCache.clear()
        try? FileManager.default.removeItem(at: Self.fileURL())
        UserDefaults.standard.removeObject(forKey: Self.uuidKey)
        persist()
    }

    func importPhoto(_ original: Data) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        errorMessage = nil
        let compressed = await Task.detached(priority: .utility) {
            Self.downsample(original)
        }.value
        guard !Task.isCancelled else { return }
        guard let compressed else {
            errorMessage = "A foto não pôde ser lida. Escolha outra imagem."; return
        }
        do {
            let url = Self.fileURL()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try compressed.write(to: url, options: [.atomic])
            let id = UUID()
            settings = PersonalBackgroundSettings(enabled: true)
            snapshot = PersonalBackgroundSnapshot(id: id, imageData: compressed, settings: settings)
            UserDefaults.standard.set(id.uuidString, forKey: Self.uuidKey)
            PersonalBackgroundRenderCache.clear()
            persist()
        } catch {
            errorMessage = "Não foi possível salvar a foto neste iPhone."
        }
    }

    private func persist() {
        if let bytes = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(bytes, forKey: Self.settingsKey)
        }
    }

    /// ImageIO thumbnail respects EXIF orientation and never decodes gigantic
    /// camera photos at their original resolution. No metadata is forwarded.
    nonisolated static func downsample(_ data: Data) -> Data? {
        guard data.count > 0, data.count <= 40 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2304,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(encoder, image,
            [kCGImageDestinationLossyCompressionQuality: 0.84] as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { return nil }
        return output as Data
    }
}

struct PersonalBackgroundAdjustmentSheet: View {
    let store: PersonalBackgroundStore
    private func value(_ read: @escaping (PersonalBackgroundSettings) -> Double,
                       update: @escaping (inout PersonalBackgroundSettings, Double) -> Void) -> Binding<Double> {
        Binding(get: { read(store.settings) }, set: { value in store.update { update(&$0, value) } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Minha foto").font(.headline)
            if let image = store.activeImage {
                PersonalBackgroundImageView(image: image, settings: store.settings)
                    .frame(height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            Text("Zoom").font(.caption)
            Slider(value: value({ $0.scale }, update: { $0.scale = $1 }), in: 1...2)
                .accessibilityIdentifier("background.photoZoom")
            HStack {
                Text("Posição horizontal").font(.caption)
                Spacer()
                Text("Posição vertical").font(.caption)
            }
            HStack {
                Slider(value: value({ $0.offsetX }, update: { $0.offsetX = $1 }), in: -0.5...0.5)
                Slider(value: value({ $0.offsetY }, update: { $0.offsetY = $1 }), in: -0.5...0.5)
            }
            Text("Escurecimento").font(.caption)
            Slider(value: value({ $0.dimming }, update: { $0.dimming = $1 }), in: 0.15...0.75)
                .accessibilityIdentifier("background.photoDimming")
            Button("Restaurar enquadramento") {
                store.update {
                    $0.scale = 1; $0.offsetX = 0; $0.offsetY = 0; $0.dimming = 0.38
                }
            }
            .font(.caption)
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(.regularMaterial)
        .accessibilityIdentifier("background.photoAdjustments")
    }
}
