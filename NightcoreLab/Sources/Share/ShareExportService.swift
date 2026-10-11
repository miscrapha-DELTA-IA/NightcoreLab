import SwiftUI
import UIKit

/// Retained only until the native share sheet is dismissed.
struct ShareExportPayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ShareExportService: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
