import Foundation

public extension Tab {
    /// The title a tab shows when the user has not named it.
    ///
    /// This lives in MyTermCore because the Mac window and the wire projection must agree. A device
    /// showing a different title from the pane it mirrors is a bug the user cannot explain.
    var automaticDisplayTitle: String {
        guard let browser = focusedBrowserSession else { return "Terminal" }
        return browser.url.host ?? "Browser"
    }

    /// What to show for this tab, preferring a name the user chose.
    var displayTitle: String {
        customTitle ?? automaticDisplayTitle
    }
}
