import SwiftUI
import UIKit

/// Captures the presented result's actual hosting view, including its loaded
/// artwork, typography, material and layout. It never builds a Story/composer.
@MainActor
final class KaraokeResultCapture {
    weak var anchor: UIView?
    func image(scale: CGFloat) throws -> UIImage {
        var responder: UIResponder? = anchor
        while let current = responder {
            if let controller = current as? UIViewController,
               controller.view.window != nil, !controller.view.bounds.isEmpty {
                return try Self.image(of: controller.view, scale: scale)
            }
            responder = current.next
        }
        throw ShareRenderError.unableToRender
    }
    static func image(of view: UIView, scale: CGFloat) throws -> UIImage {
        guard !view.bounds.isEmpty, scale.isFinite, scale > 0 else { throw ShareRenderError.unableToRender }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale; format.opaque = true
        var rendered = false
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
            rendered = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard rendered else { throw ShareRenderError.unableToRender }
        return image
    }
}

struct KaraokeResultCaptureAnchor: UIViewRepresentable {
    let capture: KaraokeResultCapture
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        capture.anchor = view
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { capture.anchor = view }
}
