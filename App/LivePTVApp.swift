import LivePTVUI
import SwiftUI

// 🐱 The whole app lives in the LivePTVKit package; this target only provides the entry point,
// 🐱 Info.plist (Local Network / camera usage strings, Files app access) and the Wi-Fi entitlements.
@main
struct LivePTVApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
