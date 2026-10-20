import SwiftUI
import SDWebImageSwiftUI

@main
struct NightcoreLabApp: App {
    @UIApplicationDelegateAdaptor(NightcoreAppDelegate.self) private var appDelegate
    @State private var lyricsStore = LyricsStore()
    @State private var panelStore = PanelStore()
    @State private var playHistory = PlayHistoryStore()

    init() {
        SDImageCache.shared.config.maxMemoryCost = 64 * 1024 * 1024
        SDImageCache.shared.config.maxDiskSize = 256 * 1024 * 1024
        SDImageCache.shared.config.maxDiskAge = 7 * 24 * 60 * 60
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(lyricsStore)
                .environment(panelStore)
                .environment(playHistory)
                .modifier(EnergyBudgetProvider())
        }
    }
}

final class NightcoreAppDelegate: NSObject, UIApplicationDelegate {
    private let performanceMetrics = LocalPerformanceMetrics()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        performanceMetrics.start()
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        performanceMetrics.stop()
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if identifier == StemModelDownload.backgroundIdentifier {
            StemModelDownload.shared.setBackgroundCompletionHandler(completionHandler)
            return
        }
        guard identifier == AudioDownloadManager.backgroundIdentifier else {
            completionHandler()
            return
        }
        AudioDownloadManager.shared.backgroundCompletionHandler = completionHandler
    }
}
