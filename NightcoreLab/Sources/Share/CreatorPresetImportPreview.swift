import SwiftUI
import UIKit

/// Frozen once on file-import confirmation, using the existing Story pipeline.
struct CreatorPresetImportSession {
    let request: StoryVideoRequest
    let profile: StoryEncodingProfile
    let frame: StoryRenderFrame

    init(preset: CreatorPreset, source: StoryVideoRequest) {
        let resolved = preset.applying(to: source)
        let encoding = preset.exportProfile.encodingProfile(for: resolved.mode)
        request = resolved
        profile = encoding
        frame = StoryRenderTimeline(request: resolved, profile: encoding).frame(index: 0)
    }
}

/// Import review is intentionally read-only: nothing is applied or persisted
/// until the user explicitly taps Apply.
struct CreatorPresetImportPreview: View {
    let imported: CreatorPresetImportResult
    let session: CreatorPresetImportSession
    let artwork: UIImage?
    let visualTimeline: AudioFeatureTimeline?
    let visualRhythm: RhythmAnalysisResult?
    let onApply: (CreatorPreset) -> Void
    let onCancel: () -> Void

    init(imported: CreatorPresetImportResult,
         source: StoryVideoRequest, artwork: UIImage?,
         visualTimeline: AudioFeatureTimeline?,
         visualRhythm: RhythmAnalysisResult?,
         onApply: @escaping (CreatorPreset) -> Void,
         onCancel: @escaping () -> Void) {
        self.imported = imported
        session = CreatorPresetImportSession(preset: imported.package.preset,
                                             source: source)
        self.artwork = artwork
        self.visualTimeline = visualTimeline
        self.visualRhythm = visualRhythm
        self.onApply = onApply
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    let canvas = StoryExportCanvas(
                        request: session.request, artwork: artwork,
                        frame: session.frame, profile: session.profile,
                        visualTimeline: visualTimeline, visualRhythm: visualRhythm)
                    GeometryReader { proxy in
                        let size = canvas.logicalSize
                        let scale = min(proxy.size.width / size.width,
                                        proxy.size.height / size.height)
                        canvas
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: size.width * scale,
                                   height: size.height * scale,
                                   alignment: .topLeading)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    }
                    .aspectRatio(CGFloat(session.profile.width) /
                                 CGFloat(session.profile.height), contentMode: .fit)
                    .frame(maxHeight: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    Text(imported.package.name)
                        .font(.title3.bold())
                    Text("Por \(imported.package.author)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    LabeledContent("Experiência", value: experienceName)
                    LabeledContent("Material", value: materialName)
                    LabeledContent("Tipografia",
                                   value: imported.package.preset.typography.style.title)
                    LabeledContent("Formato",
                                   value: imported.package.preset.exportProfile.aspectRatio.label)
                    LabeledContent("Qualidade",
                                   value: imported.package.preset.exportProfile.quality.label)

                    if !imported.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Alguns valores foram substituídos",
                                  systemImage: "exclamationmark.triangle")
                                .font(.subheadline.bold())
                            ForEach(Array(imported.warnings.enumerated()), id: \.offset) { _, warning in
                                Text(warning.message)
                                    .font(.caption)
                            }
                        }
                        .foregroundStyle(.orange)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    }
                    Text("A prévia usa o mesmo StoryFrameRenderer do exportador. O preset só será aplicado após sua confirmação.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Importar CreatorPreset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar", action: onCancel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Aplicar") { onApply(imported.package.preset) }
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var experienceName: String {
        if let experience = CreativePresetCatalog.selectedExperience(
            id: imported.package.preset.experienceID) {
            return experience.name
        }
        return CreativePresetCatalog.program(
            for: imported.package.preset.experienceID).preset.name
    }

    private var materialName: String {
        VisualMaterialCatalog.all.first {
            $0.id == imported.package.preset.materialID
        }?.name ?? VisualMaterialCatalog.originalMarble.name
    }
}
