import SwiftUI
import SDWebImageSwiftUI

@main
struct NightcoreLabApp: App {
    @UIApplicationDelegateAdaptor(NightcoreAppDelegate.self) private var appDelegate

    init() {
        SDImageCache.shared.config.maxMemoryCost = 64 * 1024 * 1024
        SDImageCache.shared.config.maxDiskSize = 256 * 1024 * 1024
        SDImageCache.shared.config.maxDiskAge = 7 * 24 * 60 * 60
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

final class NightcoreAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == AudioDownloadManager.backgroundIdentifier else {
            completionHandler()
            return
        }
        AudioDownloadManager.shared.backgroundCompletionHandler = completionHandler
    }
}
