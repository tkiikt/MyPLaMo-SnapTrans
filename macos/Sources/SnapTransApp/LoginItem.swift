import AppKit
import ServiceManagement

/// "Open at login" via SMAppService.mainApp (macOS 13+): the app itself is the login item, listed under System
/// Settings → General → Login Items & Extensions → "Open at Login". Works for the ad hoc signed distribution build and
/// from any folder (/Applications, ~/Applications, a ZIP extraction folder): the item records the app's bundle, and if
/// the app is moved or deleted it simply stops launching (the toggle then reads off). Nothing is written to settings.json:
/// the switch always shows SMAppService's live status, so turning it off in System Settings is reflected here.
@MainActor
enum LoginItem {
    enum State: Equatable {
        case off, on
        /// Registered, but the user turned it off in System Settings (or macOS wants approval): it will not launch.
        case requiresApproval
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .requiresApproval
        default: return .off   // .notRegistered, .notFound
        }
    }

    /// Returns nil on success, otherwise a short code for the log (no paths).
    @discardableResult
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            let ns = error as NSError
            // Unregistering something that is not registered is not a failure.
            if !on && state == .off { return nil }
            return "\(ns.domain) \(ns.code)"
        }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// True when macOS launched the app as a login item: the launch ("open application") Apple event then carries
    /// keyAEPropData = keyAELaunchedAsLogInItem. Valid only while that event is being handled, i.e. inside
    /// applicationDidFinishLaunching. A launch from Finder, Spotlight or `open` does not set it.
    static func launchedAtLogin() -> Bool {
        guard let e = NSAppleEventManager.shared().currentAppleEvent, e.eventClass == kCoreEventClass,
              e.eventID == kAEOpenApplication else { return false }
        return e.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
