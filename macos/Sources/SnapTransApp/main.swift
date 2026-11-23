import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: AppController?
    func applicationDidFinishLaunching(_ n: Notification) {
        let c = AppController()
        controller = c
        c.start()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }
    func applicationWillTerminate(_ n: Notification) { AppLog.log("terminate") }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // menu bar only (LSUIElement in the bundle), no Dock icon
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
