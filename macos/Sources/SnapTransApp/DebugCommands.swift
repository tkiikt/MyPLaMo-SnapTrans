import AppKit
import SnapTransCore

/// Test-only remote control, active only when SNAPTRANS_DEBUG_COMMANDS=1 (never in normal use). Commands arrive as
/// distributed notifications named "io.github.tkiikt.MyPLaMo-SnapTrans.debug" with the command in `object`, e.g.
///   select <x> <y> <w> <h>   translate a CG-global rectangle (points), as if it had been dragged
///   frame <x> <y> <w> <h>    show the passive selection frame over that rectangle (for screenshots); "frame off" hides it
///   idrag <x1> <y1> <x2> <y2> feed a drag into the interactive overlay (after "interactive"); "cancel-select" = Esc
///   interactive | last | menu | settings | quit
///   scroll <section-id>      scroll Settings (model, device, shortcut, permissions, translation, ocr, appearance, last, about)
///   lang <auto|ja-JP|en-US> | theme <system|light|dark> | device <auto|cpu> | model <id>
@MainActor
enum DebugCommands {
    static let name = Notification.Name("io.github.tkiikt.MyPLaMo-SnapTrans.debug")
    static var scrollRequest: ((String) -> Void)?

    static func install(_ app: AppController) {
        // "1" listens on the base name; any other value listens on "<base>.<value>" only (several test instances).
        guard let v = ProcessInfo.processInfo.environment["SNAPTRANS_DEBUG_COMMANDS"], !v.isEmpty else { return }
        let listen = v == "1" ? name : Notification.Name(name.rawValue + "." + v)
        AppLog.log("debug commands enabled")
        DistributedNotificationCenter.default().addObserver(forName: listen, object: nil, queue: .main) { n in
            let cmd = (n.object as? String) ?? ""
            MainActor.assumeIsolated { run(cmd, app) }
        }
    }

    static func run(_ cmd: String, _ app: AppController) {
        let p = cmd.split(separator: " ").map(String.init)
        guard let head = p.first else { return }
        let nums = p.dropFirst().compactMap { Double($0) }
        AppLog.log("debug: \(head)")
        switch head {
        case "select" where nums.count == 4: app.run(CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3]))
        case "frame" where nums.count == 4:
            app.overlay.begin(at: CGPoint(x: nums[0], y: nums[1]))
            app.overlay.move(to: CGPoint(x: nums[0] + nums[2], y: nums[1] + nums[3]))
        case "frame": app.overlay.close()
        case "interactive": app.startInteractiveSelection()
        case "cancel-select": app.overlay.finishInteractive(nil)
        case "idrag" where nums.count == 4:
            // Feeds a left drag (CG-global points) into the interactive overlay through NSWindow.sendEvent.
            app.overlay.debugDrag(from: CGPoint(x: nums[0], y: nums[1]), to: CGPoint(x: nums[2], y: nums[3]))
        case "last": app.showLast()
        case "menu": app.statusItem?.showMenu()
        case "settings": app.openSettings()
        case "close-settings": app.settingsWindow?.window.orderOut(nil)
        case "hide-popup": app.popup.hide()
        case "quit": app.quit()
        case "status":
            AppLog.log("status: AXIsProcessTrusted=\(Permissions.accessibility) CGPreflightScreenCaptureAccess=\(Permissions.screenRecording) CGPreflightListenEventAccess=\(CGPreflightListenEventAccess()) tap=\(app.input.isInstalled)")
        case "scroll" where p.count > 1: scrollRequest?(p[1])
        case "lang" where p.count > 1: app.settings.language = p[1]; app.applyLanguage(); app.settingsWindow?.window.title = Loc.t("Settings_Title")
        case "theme" where p.count > 1: app.settings.theme = p[1]; app.applyTheme()
        case "device" where p.count > 1: Task { await app.applyEngineChange { app.settings.device = p[1] } }
        case "model" where p.count > 1: if let m = ModelInfo.find(p[1]) { app.downloads.use(m) }
        default: AppLog.log("debug: unknown command")
        }
    }
}
