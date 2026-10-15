import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import NightcoreLab

final class ShareExportPipelineTests: XCTestCase {
    @MainActor
    func testFourLyricModelsFreezeIntoShareAndRenderDistinctStoryFrames() throws {
        let track = TrackInfo(track: Track(id: "models-31", title: "Artist - Four Styles",
            thumbnailURL: nil), fileName: nil, coverURL: nil)
        let line = TimedLyricLine(id: 1, start: 1, end: 8, words: [
            WordSync(id: 0, text: "STORY", start: 1, end: 4, spaceAfter: true),
            WordSync(id: 1, text: "CANTO", start: 4, end: 8, spaceAfter: false)
        ], precision: .word)
        var rendered = Set<Data>()
        var physicalLayers = Set<String>()
        for style in TypographyStyle.storyObjectModels {
            let snapshot = ShareSnapshotBuilder.make(track: track, theme: .acid,
                visualStyle: .marble, marbleStartedAt: .now, speed: 1,
                typographyStyle: style)
            XCTAssertEqual(snapshot.typographyStyle, style)
            let request = try StoryRequestBuilder.make(mode: .lyrics, track: track,
                theme: snapshot.theme, playerStyle: .turbulent,
                karaokeBackground: .marble, marblePhase: 0,
                playbackTime: 2, sourceDuration: 12, speed: 1,
                lines: [line], lyricOffset: 0, typography: .classic,
                typographyStyle: snapshot.typographyStyle, includeAudio: false)
            let profile = StoryEncodingProfile.economical
            let frame = StoryRenderTimeline(request: request, profile: profile).frame(index: 0)
            let scene = StorySceneView(request: request, artwork: nil, frame: frame)
            let typography = try XCTUnwrap(scene.typographyFrame)
            XCTAssertEqual(typography.preset.style, style)
            XCTAssertEqual(typography,
                request.typographyLayer(atLyricTime: frame.lyricTime)?
                    .resolve(at: frame.lyricTime, features: nil))
            let word = try XCTUnwrap(typography.words.first)
            if style == .magazineCutout {
                XCTAssertNotNil(word.magazine)
            } else {
                let appearance = try XCTUnwrap(ObjectWordStyleResolver.resolve(
                    style: style, seed: word.seed, progress: word.progress))
                XCTAssertEqual(appearance.fill, word.progress)
                physicalLayers.insert(appearance.material.rawValue)
            }
            let image = try StoryFrameRenderer.render(request: request, artwork: nil,
                frame: frame, profile: profile)
            rendered.insert(try XCTUnwrap(image.dataProvider?.data) as Data)
        }
        XCTAssertEqual(physicalLayers.count, 3)
        XCTAssertEqual(rendered.count, 4)
    }

    @MainActor
    func testCreatorAndShareUseFrozenTrackHeaderAndOfficialBrand() throws {
        let artworkURL = URL(fileURLWithPath: "/tmp/stage28-cover.jpg")
        let track = TrackInfo(track: Track(id: "stage28", title: "Stage 28 Song",
            thumbnailURL: artworkURL, cleanArtist: "Stage 28 Artist"),
            fileName: nil, coverURL: artworkURL)
        let snapshot = ShareSnapshotBuilder.make(track: track, theme: .acid,
            visualStyle: .marble, marbleStartedAt: .now, speed: 1)
        XCTAssertEqual(snapshot.title, track.title)
        XCTAssertEqual(snapshot.artist, track.artist)
        XCTAssertEqual(snapshot.artworkURL, artworkURL)
        let request = try StoryRequestBuilder.make(mode: .player, track: track,
            theme: .acid, playerStyle: .turbulent, karaokeBackground: .marble,
            marblePhase: 0, playbackTime: 0, sourceDuration: 10, speed: 1,
            lines: [], lyricOffset: 0, typography: .classic, includeAudio: false)
        XCTAssertEqual(request.title, track.title)
        XCTAssertEqual(request.artist, track.artist)
        XCTAssertEqual(request.artworkURL, artworkURL)

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("NightcoreLab/Sources")
        for file in ["NowPlayingScreen.swift", "Share/StoryDraftPreview.swift",
                     "Share/StorySceneView.swift", "Share/ShareComposer.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(file))
            XCTAssertTrue(source.contains("NightcoreBrandLockup"), file)
            XCTAssertTrue(source.contains("TrackIdentityPill"), file)
            XCTAssertFalse(source.contains("\"NIGHTCORELAB\""), file)
        }
    }
    private func request(mode: StoryMode = .player,
                         duration: TimeInterval = 120) throws -> StoryVideoRequest {
        let track = TrackInfo(
            track: Track(id: "12345678901", title: "Export Sample",
                         thumbnailURL: nil, cleanArtist: "Test Artist"),
            fileName: nil, coverURL: nil)
        return try StoryRequestBuilder.make(
            mode: mode, track: track, theme: .acid,
            playerStyle: .turbulent, karaokeBackground: .marble,
            marblePhase: 2.1, playbackTime: duration - 0.35,
            sourceDuration: duration, speed: 1, lines: [],
            lyricOffset: 0, typography: .classic, includeAudio: false)
    }

    func testLegacyRecommendedProfileDoesNotChange() {
        let old = StoryEncodingProfile.recommended()
        let profile = ExportProfile.matching(old).encodingProfile(for: .player)
        XCTAssertEqual(old.width, profile.width)
        XCTAssertEqual(old.height, profile.height)
        if old.fps == StoryEncodingProfile.economical.fps {
            XCTAssertEqual(profile.fps, 15)
            XCTAssertEqual(profile.bitRate, old.bitRate)
        } else {
            XCTAssertEqual(profile.fps, 30)
            XCTAssertGreaterThan(profile.bitRate, old.bitRate)
        }
        XCTAssertEqual(profile.cropPolicy, .safeAreaPreserving)
    }

    func testFormatQualityMatrixAndFrameRate() {
        for quality in ExportQuality.allCases {
            for ratio in ExportAspectRatio.allCases {
                let profile = ExportProfile(
                    aspectRatio: ratio, quality: quality
                ).encodingProfile(for: .player)
                let expected: (Int, Int)
                switch ratio {
                case .portrait: expected = (9, 16)
                case .square: expected = (1, 1)
                case .landscape: expected = (16, 9)
                }
                XCTAssertEqual(profile.width * expected.1,
                               profile.height * expected.0)
                XCTAssertEqual(profile.width % 2, 0)
                XCTAssertEqual(profile.height % 2, 0)
                XCTAssertGreaterThan(profile.bitRate, 0)
                XCTAssertEqual(profile.fps, quality == .economy ? 15 :
                               quality == .balanced ? 30 : 60)
            }
        }
        XCTAssertEqual(ExportProfile().encodingProfile(for: .player).width, 720)
        XCTAssertEqual(ExportProfile().encodingProfile(for: .player).height, 1280)
    }

    func testLyricsNeverUseUnsafeCenterCrop() {
        let crop = ExportProfile(aspectRatio: .landscape,
                                 quality: .balanced, cropPolicy: .centerCrop)
        XCTAssertEqual(crop.encodingProfile(for: .lyrics).cropPolicy,
                       .safeAreaPreserving)
        XCTAssertEqual(crop.encodingProfile(for: .player).cropPolicy,
                       .centerCrop)
    }

    func testProfileCodableRoundTripAndMetadataVersion() throws {
        let value = ExportProfile(aspectRatio: .square, quality: .high,
                                  cropPolicy: .aspectFit)
        let bytes = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(ExportProfile.self, from: bytes), value)

        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = ShareMetadata(
            schemaVersion: 1, title: "Song", artist: "Artist",
            presetID: "original", materialID: "original-marble",
            duration: 4, width: 720, height: 720, fps: 20,
            codec: "h264", quality: .balanced, aspectRatio: .square,
            cropPolicy: .safeAreaPreserving,
            thumbnailFrameIndex: 0, thumbnailElapsed: 0, exportedAt: stamp)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(ShareMetadata.self,
                                          from: encoder.encode(metadata)), metadata)
    }

    func testMetadataPreservesLightningReactionAndScoreWithoutClaimingSimulationAsLive() throws {
        var score = KaraokeScoreSnapshot()
        score.judgedVerses = 2
        score.accuracyPercentage = 78
        let stamp = try XCTUnwrap(KaraokePerformanceStamp(
            snapshot: score, mode: .simulation))
        XCTAssertEqual(stamp.grade, "A")
        XCTAssertEqual(stamp.label, "SIMULAÇÃO")
        var metadata = ShareMetadata(
            schemaVersion: ShareMetadata.currentSchemaVersion,
            title: "Song", artist: "Artist", presetID: "cyber-night",
            materialID: "cyber-night", duration: 15, width: 720,
            height: 1280, fps: 20, codec: "h264", quality: .balanced,
            aspectRatio: .portrait, cropPolicy: .safeAreaPreserving,
            thumbnailFrameIndex: 0, thumbnailElapsed: 0, exportedAt: .now)
        metadata.lightningTheme = AppTheme.ultrapink.rawValue
        metadata.reactionMode = CreativePreset.AudioReaction.responsive.rawValue
        metadata.karaokeGrade = stamp.grade
        metadata.karaokeScore = stamp.score
        metadata.karaokeAccuracy = stamp.accuracy
        metadata.karaokeMode = stamp.label
        metadata.padEventCount = 2
        metadata.sectionVisualIntensity = 0.85
        let decoded = try JSONDecoder().decode(ShareMetadata.self,
            from: JSONEncoder().encode(metadata))
        XCTAssertEqual(decoded, metadata)
    }

    @MainActor
    func testSharedCanvasRendersThreeRatiosWithoutChangingSceneSource() throws {
        let clip = try request()
        for ratio in ExportAspectRatio.allCases {
            let profile = ExportProfile(aspectRatio: ratio, quality: .economy)
                .encodingProfile(for: clip.mode)
            let frame = StoryRenderTimeline(request: clip, profile: profile).frame(index: 1)
            let image = try StoryFrameRenderer.render(
                request: clip, artwork: nil, frame: frame, profile: profile)
            XCTAssertEqual(image.width, profile.width)
            XCTAssertEqual(image.height, profile.height)
        }
    }

    @MainActor
    func testDefaultPortraitPreviewAndEncoderShareExactPixels() throws {
        let clip = try request()
        let profile = StoryEncodingProfile.balanced
        let frame = StoryRenderTimeline(request: clip, profile: profile).frame(index: 1)
        let exported = try StoryFrameRenderer.render(
            request: clip, artwork: nil, frame: frame, profile: profile)
        let sameCanvas = StoryExportCanvas(request: clip, artwork: nil,
                                           frame: frame, profile: profile)
        XCTAssertTrue(sameCanvas.isLegacyPortrait)
        XCTAssertEqual(sameCanvas.logicalSize, StoryVideoRequest.size)
        let preview = ImageRenderer(content: sameCanvas)
        preview.proposedSize = ProposedViewSize(sameCanvas.logicalSize)
        preview.scale = profile.scale
        let pixels = try XCTUnwrap(preview.uiImage?.cgImage)
        XCTAssertEqual(pixels.width, exported.width)
        XCTAssertEqual(pixels.height, exported.height)

        // Regression baseline: prior to 14A, ImageRenderer directly wrapped
        // StorySceneView without any export canvas or crop adapter.
        let legacy = ImageRenderer(content: StorySceneView(
            request: clip, artwork: nil, frame: frame))
        legacy.proposedSize = ProposedViewSize(StoryVideoRequest.size)
        legacy.scale = profile.scale
        let baseline = try XCTUnwrap(legacy.uiImage?.cgImage)
        let encodedBytes = try XCTUnwrap(exported.dataProvider?.data) as Data
        let previewBytes = try XCTUnwrap(pixels.dataProvider?.data) as Data
        let baselineBytes = try XCTUnwrap(baseline.dataProvider?.data) as Data
        XCTAssertEqual(encodedBytes, baselineBytes,
                       "Default portrait pixels must match the old StorySceneView")
        XCTAssertEqual(previewBytes, encodedBytes,
                       "Preview and video must consume identical visual state")

        let resolved = clip.resolvedFrame(frame, audioTimeline: nil, rhythm: nil)
        XCTAssertEqual(StorySceneView(request: clip, artwork: nil, frame: frame).materialFrame,
                       resolved?.materialFrame)
    }

    @MainActor
    func testSharePackageContainsValidatedVideoThumbnailAndMetadata() async throws {
        let clip = try request()
        let profile = ExportProfile(aspectRatio: .square, quality: .economy,
                                    cropPolicy: .safeAreaPreserving)
        let output = try await SharePackageBuilder.build(
            request: clip, audioSource: nil, artwork: nil,
            selectedProfile: profile, visualTimeline: nil, visualRhythm: nil,
            progress: { _ in })
        defer { try? FileManager.default.removeItem(
            at: output.videoURL.deletingLastPathComponent()) }
        XCTAssertEqual(output.files.count, 3)
        for file in output.files {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            XCTAssertGreaterThan(try Data(contentsOf: file).count, 0)
        }
        let bytes = try Data(contentsOf: output.metadataURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // The sidecar's ISO-8601 contract stores seconds, whereas Date() in
        // SharePackage.metadata retains subsecond precision. Assert exact
        // serialized content rather than incorrectly comparing those Dates.
        XCTAssertEqual(bytes, try encoder.encode(output.metadata),
                       "Persisted sidecar must match the full in-memory metadata")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(ShareMetadata.self, from: bytes)
        let expectedPersisted = try decoder.decode(
            ShareMetadata.self, from: encoder.encode(output.metadata))
        XCTAssertEqual(metadata, expectedPersisted,
                       "Every ShareMetadata field must survive its declared JSON contract")

        // Independent profile expectations; do not mistake Square + Economy
        // for the legacy portrait dimensions.
        let encoding = profile.encodingProfile(for: clip.mode)
        XCTAssertEqual(metadata.schemaVersion, ShareMetadata.currentSchemaVersion)
        XCTAssertEqual(metadata.quality, profile.quality)
        XCTAssertEqual(metadata.aspectRatio, profile.aspectRatio)
        XCTAssertEqual(metadata.cropPolicy, encoding.cropPolicy)
        XCTAssertEqual(metadata.codec, "h264")
        XCTAssertEqual(metadata.width, encoding.width)
        XCTAssertEqual(metadata.height, encoding.height)
        XCTAssertEqual(metadata.fps, encoding.fps)
        XCTAssertEqual(metadata.width, 540)
        XCTAssertEqual(metadata.height, 540)
        XCTAssertEqual(metadata.thumbnailFrameIndex, 0)
        let thumb = try XCTUnwrap(UIImage(contentsOfFile: output.thumbnailURL.path))
        XCTAssertEqual(thumb.cgImage?.width, 540)
        XCTAssertEqual(thumb.cgImage?.height, 540)

        let asset = AVURLAsset(url: output.videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(tracks.first)
        let size = try await video.load(.naturalSize)
        XCTAssertEqual(size.width, CGFloat(encoding.width))
        XCTAssertEqual(size.height, CGFloat(encoding.height))
        XCTAssertEqual(metadata.thumbnailElapsed, 0)
        XCTAssertFalse(output.videoURL.path.hasPrefix(
            FileManager.default.temporaryDirectory.path))
        output.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.videoURL.path))
    }

    @MainActor
    func testStage37ShareReactivityOffIsSilentWhilePaletteAndPhaseStayLive() throws {
        let clip = try request(mode: .player, duration: 30)
        var silent = clip
        silent.reactionMode = .off
        silent.liveVisualResponseEnabled = true
        silent.songDNA = SongDNA(assetID: "fixture", sourceRevision: "r1",
                                 sourceDuration: 30, beatTimestamps: [29.65])
        let profile = StoryEncodingProfile(width: 270, height: 480,
                                           fps: 30, bitRate: 700_000)
        let frames = (0..<4).map { StoryRenderTimeline(request: silent,
                                                       profile: profile).frame(index: $0) }
        for frame in frames {
            let scene = StorySceneView(request: silent, artwork: nil, frame: frame)
            XCTAssertEqual(scene.exportMaterialFrame.parameters.beatPulse, 0)
            XCTAssertEqual(scene.exportMaterialFrame.signals.energy, 0)
            XCTAssertEqual(scene.exportMaterialFrame.signals.movement, 0)
            XCTAssertEqual(scene.exportMaterialFrame.audioResponse.pulse, 0)
        }
        XCTAssertGreaterThan(frames[1].marblePhase, frames[0].marblePhase)
        XCTAssertEqual(silent.theme, clip.theme)
        let snapshot = ShareSnapshotBuilder.make(
            track: TrackInfo(track: nil, fileName: "Stage37.mp3", coverURL: nil),
            theme: .cyber, visualStyle: .marble,
            marbleStartedAt: .now, speed: 0.6, reactionMode: .off)
        XCTAssertEqual(snapshot.reactionMode, .off)
        XCTAssertEqual(snapshot.theme, .cyber)
    }

    func testStage37ShareCustomizerReplacesCreatorMazeAndAddsDirectPNG() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("NightcoreLab/Sources")
        let ui = try String(contentsOf: root.appendingPathComponent("Share/StoryDraftPreview.swift"),
                             encoding: .utf8)
        for title in ["Fundo & Movimento", "Estilo da Legenda", "Exibir no Card",
                      "Desligado", "Fluido", "Reativo", "Magazine", "Sticker",
                      "Dymo", "Cristal ⚡", "Sem Legenda", "Capa & Música",
                      "Placar Karaokê", "Marca Nightcore Lab",
                      "Exportar Vídeo (.mp4)", "Salvar Imagem"] {
            XCTAssertTrue(ui.contains(title), "Missing direct export control \(title)")
        }
        XCTAssertFalse(ui.contains("DisclosureGroup(\"Creator Controls\")"))
        XCTAssertFalse(ui.contains("navigationTitle(\"Creator Studio\")"))
        XCTAssertTrue(ui.contains("NightcoreBrandLockup"))
        XCTAssertTrue(ui.contains("thumbnailSize: 76"))
        XCTAssertTrue(ui.contains("StoryFrameRenderer.render"))
        XCTAssertTrue(ui.contains("share.reactivityMode"))
        XCTAssertTrue(ui.contains("share.cardToggles"))
    }

}

extension ShareExportPipelineTests {
    /// Measure only the unobstructed center: titles, lyric tiles and logos
    /// must not let an empty/blurred background pass the contrast gate.
    private func centerPixels(_ image: CGImage) throws -> [Double] {
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let context = try XCTUnwrap(CGContext(data: &rgba, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var result: [Double] = []
        for y in h/4..<h*3/4 {
            for x in w/4..<w*3/4 {
                let i = (y * w + x) * 4
                result.append(contentsOf: rgba[i..<i+3].map { Double($0) / 255 })
            }
        }
        return result
    }

    @MainActor
    func testStage40RealMetalContrastPaletteAndContinuousFrames() throws {
        defer { StoryMetalSurface.shared.releaseTarget() }
        let track = TrackInfo(track: Track(id: "crisp", title: "The Adults Are Talking",
            thumbnailURL: nil), fileName: nil, coverURL: nil)
        let profile = StoryEncodingProfile(width: 270, height: 480, fps: 30, bitRate: 700_000)
        for experience in CreativePresetCatalog.selectableExperiences {
            for theme in [AppTheme.lagoon, .cyber] {
                var request = try StoryRequestBuilder.make(mode: .player, track: track,
                    theme: theme, playerStyle: .turbulent, karaokeBackground: .marble,
                    marblePhase: 2.1, playbackTime: 0, sourceDuration: 10, speed: 1,
                    lines: [], lyricOffset: 0, typography: .classic, includeAudio: false,
                    creativePresetID: experience.id, reactionMode: .off)
                request.showsTrackCard = false
                request.showsBrand = false
                request.showsLyrics = false
                let timeline = StoryRenderTimeline(request: request, profile: profile)
                func pixels(_ index: Int) throws -> [Double] {
                    try centerPixels(StoryFrameRenderer.render(request: request, artwork: nil,
                        frame: timeline.frame(index: index), profile: profile))
                }
                let first = try pixels(0)
                let next = try pixels(1)
                let third = try pixels(2)
                XCTAssertEqual(first, try pixels(0), "Out-of-order render must be deterministic")
                var luminance: [Double] = []
                var saturation = 0.0
                for i in stride(from: 0, to: first.count, by: 3) {
                    let r = first[i], g = first[i+1], b = first[i+2]
                    luminance.append(0.2126*r + 0.7152*g + 0.0722*b)
                    let high = max(r, max(g, b)), low = min(r, min(g, b))
                    saturation += high > 0 ? (high-low)/high : 0
                }
                let mean = luminance.reduce(0,+) / Double(luminance.count)
                let variance = luminance.reduce(0) { $0 + pow($1-mean, 2) } / Double(luminance.count)
                let rowWidth = profile.width*3/4 - profile.width/4
                var gradient = 0.0, count = 0
                for i in 0..<luminance.count where i % rowWidth < rowWidth-4 {
                    gradient += abs(luminance[i+4] - luminance[i]); count += 1
                }
                gradient /= Double(count)
                let label = "\(experience.id)/\(theme): variance=\(variance), gradient=\(gradient)"
                print("Stage40 pixels: \(label)")
                XCTAssertGreaterThan(variance, 0.0005, label)
                XCTAssertGreaterThan(gradient, 0.002, label)
                XCTAssertGreaterThan(saturation/Double(luminance.count), 0.15, label)
                for pair in [(first, next), (next, third)] {
                    let delta = zip(pair.0, pair.1).reduce(0.0) { $0 + abs($1.0-$1.1) } / Double(first.count)
                    XCTAssertGreaterThan(delta, 0.00001, "Frozen frame: \(label)")
                    XCTAssertLessThan(delta, 0.08, "Discontinuous frame: \(label)")
                }
            }
        }
    }
}
