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

    var body: some View {
        GeometryReader { geo in
            if let image = try? StoryMetalSurface.shared.render(
                size: geo.size, theme: theme, frame: materialFrame,
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
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let pipeline: MTLComputePipelineState?
    private var target: MTLTexture?
    private(set) var lastError: Error?
    private var memoryObserver: NSObjectProtocol?

    private init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        queue = device?.makeCommandQueue()
        if let function = device?.makeDefaultLibrary()?.makeFunction(name: "storyMarbleFrame") {
            pipeline = try? device?.makeComputePipelineState(function: function)
        } else { pipeline = nil }
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.releaseTarget() }
            }
    }

    func beginFrame() { lastError = nil }

    func releaseTarget() { target = nil }

    func render(size: CGSize, theme: AppTheme, frame: MaterialFrame,
                phase: Float) throws -> CGImage {
        do {
            let result = try draw(size: size, theme: theme, frame: frame, phase: phase)
            lastError = nil
            return result
        } catch {
            lastError = error
            throw error
        }
    }

    private func draw(size: CGSize, theme: AppTheme, frame: MaterialFrame,
                      phase: Float) throws -> CGImage {
        guard let device, let queue, let pipeline else { throw StoryVideoError.renderFailed }
        // The authored 540×960 scene is sampled at native 1080×1920. Keep
        // logical coordinates identical to SwiftUI for screen-space textures.
        let width = max(1, Int((size.width * 2).rounded()))
        let height = max(1, Int((size.height * 2).rounded()))
        if target?.width != width || target?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderWrite]
            descriptor.storageMode = .shared
            target = device.makeTexture(descriptor: descriptor)
        }
        guard let target, let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            throw StoryVideoError.renderFailed
        }
        let palette = MarbleTheme(appTheme: theme).palette
        let binding = MarbleSurfaceBinding.resolve(frame: frame)
        let authored = TurbulentMarbleView.shaderPalette(materialID: frame.materialID,
            theme: MarbleTheme(appTheme: theme), authored: binding.paletteHex)
        let colors = binding.textured ? authored! :
            [palette.deep, palette.body, palette.glow, palette.body, palette.glow]
        var rgba = colors.map { color -> SIMD4<Float> in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            return SIMD4(Float(r), Float(g), Float(b), Float(a))
        }
        let u = frame.marbleUniforms
        var values: [Float] = [Float(size.width), Float(size.height), phase,
            binding.textured ? 2 : (frame.type == .marble ? 0 : 1),
            Float(u.stripingFrequency), Float(u.stripingMix), Float(u.speckleIntensity),
            Float(u.embossStrength), Float(u.scanlineDensity), Float(u.diffusionSoftness),
            Float(u.voidThreshold), Float(u.combStretch), Float(u.bilateralSymmetry),
            Float(u.halftoneGrating), Float(u.distortion), Float(u.beatPulse),
            Float(u.warpAmount), Float(u.brightnessBoost), frame.type.shaderID,
            Float(frame.controls.primary), Float(frame.controls.secondary),
            Float(frame.controls.tertiary), Float(frame.controls.quaternary),
            Float(frame.signals.energy), Float(frame.signals.bass),
            Float(frame.signals.movement), Float(frame.signals.brightness),
            Float(frame.seed % 65536)]
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(target, index: 0)
        encoder.setBytes(&values, length: values.count * MemoryLayout<Float>.stride, index: 0)
        encoder.setBytes(&rgba, length: rgba.count * MemoryLayout<SIMD4<Float>>.stride, index: 1)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw StoryVideoError.renderFailed }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw StoryVideoError.renderFailed }
        return image
    }
}
