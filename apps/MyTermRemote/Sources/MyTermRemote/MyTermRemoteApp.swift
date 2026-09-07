import SwiftUI

@main
struct MyTermRemoteApp: App {
    init() {
        // The UI tests need a device that has never paired. Nothing else sets this.
        if ProcessInfo.processInfo.environment["MYTERM_REMOTE_RESET_STATE"] == "1",
           let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
    }

    var body: some Scene {
        WindowGroup {
            ConnectionView()
        }
    }
}
