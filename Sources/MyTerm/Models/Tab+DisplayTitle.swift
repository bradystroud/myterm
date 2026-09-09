import MyTermCore

extension Tab {
    var automaticDisplayTitle: String {
        // The agent conversation is what a pane running one is about, so its name outranks the
        // generic label. A title the user typed still wins over both.
        if let agentTitle = terminalSession?.agentTitle { return agentTitle }
        guard let browser = focusedBrowserSession else { return "Terminal" }
        return browser.url.host ?? "Browser"
    }
}
