import SwiftUI
import ComposeApp

/// The whole app is the Kotlin framework; Swift only hosts it.
/// Anything iOS-specific belongs behind an `actual` in iosMain, never here - a second implementation
/// in Swift is how two platforms drift apart.
@main
struct iOSApp: App {
    /// The Garmin watch link - kept here because Garmin Connect answers by opening our URL ([[garmin-watch-app]]).
    private let garmin = GarminLink()

    /// The one thing Swift does besides hosting: StoreKit 2 is Swift-only, so the App Store is built here
    /// and handed to Kotlin before the first screen asks for it ([[licensing-paywall]]).
    init() {
        AppleStoreBridge.shared.store = StoreKitStore()
        GarminLinkBridge.shared.bridge = garmin
    }

    var body: some Scene {
        WindowGroup {
            ComposeView().ignoresSafeArea(.keyboard)
                // A Coriolis code read by the phone's camera (our link) goes to the Scan screen; anything else
                // is Garmin Connect returning the watch the shooter chose.
                .onOpenURL { url in
                    if !IosLinks.shared.open(url: url.absoluteString) { garmin.handle(url) }
                }
                // Universal links can also arrive as a web-browsing activity.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { _ = IosLinks.shared.open(url: url.absoluteString) }
                }
        }
    }
}

struct ComposeView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        MainViewControllerKt.MainViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
