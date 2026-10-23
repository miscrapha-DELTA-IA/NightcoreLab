import SwiftUI
import Metal
import UIKit

/// A real off-screen Metal surface, using the live shader functions. No wall
/// clock, feedback textures, SwiftUI shader capture, blur or substitute artwork.
struct StoryExportMarbleView: View {
    let theme: AppTheme
    let renderTimestamp: TimeInterval
    let steadyFlowSpeed: Float
    let startingPhase: Float
    let materialFrame: MaterialFrame
    var gnarlyContext: GnarlyVisualContext? = nil

    var body: some View {
        GeometryReader { geo in
            if let image = try? StoryMetalSurface.shared.render(
                size: geo.size, theme: theme, frame: materialFrame,
                gnarlyContext: gnarlyContext,
                phase: StoryExportMotion.phase(at: renderTimestamp,
                    start: startingPhase, speed: steadyFlowSpeed)) {
                Image(decorative: image, scale: 2)
                    .resizable().interpolation(.high)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Reuses the device, pipeline, queue and one target, never a frame cache.
/// All access is serialized with the SwiftUI/Story renderer on the main actor.
@MainActor
final class StoryMetalSurface {
    static let shared = StoryMetalSurface()

    private enum Family: String {
        case liquid = "storyLiquidMarbleFrame"
        case textured = "storyTexturedMarbleFrame"
        case procedural = "storyProceduralMarbleFrame"
    }

    private enum MetalFailure: LocalizedError {
        case noGPU
        case missingLibrary
        case missingFunction(String)
        case missingTexture
        case missingCommandResources
        case commandFailed(String)
        case invalidImage

        var errorDescription: String? {
            switch self {
            case .noGPU: return "Metal device or command queue unavailable"
            case .missingLibrary: return "NightcoreLab default.metallib is missing"
            case .missingFunction(let name):
                return "Metal export kernel \(name) is missing from default.metallib"
            case .missingTexture: return "Unable to allocate Metal export target texture"
            case .missingCommandResources: return "Unable to allocate Metal command buffer/encoder"
            case .commandFailed(let details): return "Metal export command failed: \(details)"
            case .invalidImage: return "Unable to construct CGImage from BGRA Metal readback"
            }
        }
    }

    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var pipelines: [Family: MTLComputePipelineState] = [:]
    private var target: MTLTexture?
    private(set) var lastError: Error?
    private var memoryObserver: NSObjectProtocol?

    private init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        self.queue = device?.makeCommandQueue()
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.releaseTarget() }
            }
    }

    func beginFrame() { lastError = nil }

    // Pipelines (small GPU programs) remain cached; only the large texture is
    // discarded at the end of export or during memory pressure.
    func releaseTarget() { target = nil }

    private func pipeline(for family: Family, on device: MTLDevice) throws -> MTLComputePipelineState {
        if let cached = pipelines[family] { return cached }
        guard let library = device.makeDefaultLibrary() else {
            throw MetalFailure.missingLibrary
        }
        guard let function = library.makeFunction(name: family.rawValue) else {
            throw MetalFailure.missingFunction(family.rawValue)
        }
        do {
            let compiled = try device.makeComputePipelineState(function: function)
            pipelines[family] = compiled
            return compiled
        } catch {
            // Keep the original NSError/domain/code and its complete JIT
            // diagnostic; never turn a compiler error into a silent nil.
            NSLog("StoryMetalSurface pipeline '%@' compilation failed: %@",
                  family.rawValue, String(describing: error))
            throw error
        }
    }

    func render(size: CGSize, theme: AppTheme, frame: MaterialFrame,
                gnarlyContext: GnarlyVisualContext? = nil,
                phase: Float) throws -> CGImage {
        do {
            let result = try draw(size: size, theme: theme, frame: frame,
                                  gnarlyContext: gnarlyContext, phase: phase)
            lastError = nil
            return result
        } catch {
            lastError = error
            NSLog("StoryMetalSurface render failed: %@", error.localizedDescription)
            throw error
        }
    }

    private func draw(size: CGSize, theme: AppTheme, frame: MaterialFrame,
                      gnarlyContext: GnarlyVisualContext?,
                      phase: Float) throws -> CGImage {
        guard let device, let queue else { throw MetalFailure.noGPU }
        let gnarly = theme == .gnarly && gnarlyContext != nil
            ? GnarlyThemeEngine.sample(
                sourceTime: gnarlyContext!.sourceTime,
                duration: gnarlyContext!.sourceDuration,
                artworkHue: gnarlyContext!.artworkHue, base: frame)
            : nil
        let output = gnarly?.frame ?? frame
        let binding = MarbleSurfaceBinding.resolve(frame: output)
        let family: Family = binding.textured ? .textured :
            (output.type == .marble ? .liquid : .procedural)
        let pipeline = try pipeline(for: family, on: device)

        // Scene coordinates remain 540x960 for 1080x1920 output. The same
        // deterministic timestamp/phase and visual uniforms feed all formats.
        let width = max(1, Int((size.width * 2).rounded()))
        let height = max(1, Int((size.height * 2).rounded()))
        if target?.width != width || target?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height,
                mipmapped: false)
            descriptor.usage = [.shaderWrite, .shaderRead]
            descriptor.storageMode = .shared
            target = device.makeTexture(descriptor: descriptor)
        }
        guard let target else { throw MetalFailure.missingTexture }
        guard let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            throw MetalFailure.missingCommandResources
        }

        let palette = MarbleTheme(appTheme: theme).palette
        let authored = TurbulentMarbleView.shaderPalette(materialID: frame.materialID,
            theme: MarbleTheme(appTheme: theme), authored: binding.paletteHex)
        // Avoid a force unwrap for imported/past presets without authored stops.
        let colors = gnarly?.colors.map(\.color) ?? (binding.textured
            ? (authored ?? [palette.deep, palette.body, palette.glow, palette.body, palette.glow])
            : [palette.deep, palette.body, palette.glow, palette.body, palette.glow])
        let rgba: [SIMD4<Float>] = colors.map { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            return SIMD4(Float(r), Float(g), Float(b), Float(a))
        }
        let u = output.marbleUniforms
        let values: [Float] = [Float(size.width), Float(size.height), phase,
            binding.textured ? 2 : (output.type == .marble ? 0 : 1),
            Float(u.stripingFrequency), Float(u.stripingMix), Float(u.speckleIntensity),
            Float(u.embossStrength), Float(u.scanlineDensity), Float(u.diffusionSoftness),
            Float(u.voidThreshold), Float(u.combStretch), Float(u.bilateralSymmetry),
            Float(u.halftoneGrating), Float(u.distortion), Float(u.beatPulse),
            Float(u.warpAmount), Float(u.brightnessBoost), output.type.shaderID,
            Float(output.controls.primary), Float(output.controls.secondary),
            Float(output.controls.tertiary), Float(output.controls.quaternary),
            Float(output.signals.energy), Float(output.signals.bass),
            Float(output.signals.movement), Float(output.signals.brightness),
            Float(output.seed % 65536)]

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(target, index: 0)
        // Swift Array is not a C struct. Bind its contiguous ELEMENT bytes,
        // not the address of the Array header.
        values.withUnsafeBytes { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count, index: 0)
        }
        rgba.withUnsafeBytes { raw in
            encoder.setBytes(raw.baseAddress!, length: raw.count, index: 1)
        }
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            let reason = command.error.map { String(describing: $0) } ??
                "status=\(command.status.rawValue)"
            throw MetalFailure.commandFailed(reason)
        }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        // Metal BGRA8 readback is byte-order B,G,R,A. Explicit little-endian
        // premultiplied-first CGImage info preserves the actual color channels.
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent)
        else { throw MetalFailure.invalidImage }
        return image
    }
}
