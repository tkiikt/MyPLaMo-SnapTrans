import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: AppController?
    func applicationDidFinishLaunching(_ n: Notification) {
        // One SnapTrans per user (two would both swallow the same drag and translate it twice). A second launch asks
        // the running one to show Settings and quits. Test instances opt out with SNAPTRANS_ALLOW_MULTIPLE=1.
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }
        if !others.isEmpty && ProcessInfo.processInfo.environment["SNAPTRANS_ALLOW_MULTIPLE"] != "1" {
            AppLog.log("already running (pid \(others[0].processIdentifier)); asking it to open Settings")
            DistributedNotificationCenter.default().postNotificationName(AppController.showSettingsNotification, object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
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
