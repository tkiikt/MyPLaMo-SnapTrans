import AppKit
import ApplicationServices
import CoreGraphics

/// Screen Recording and Accessibility, checked without prompting. Prompts and System Settings are opened only from
/// explicit user actions in Settings (or the first capture, which macOS itself gates).
enum Permissions {
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    /// Needed for the active CGEventTap that swallows the modifier + drag (and Esc) so the app below does not see it.
    static var accessibility: Bool { AXIsProcessTrusted() }

    @discardableResult static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
