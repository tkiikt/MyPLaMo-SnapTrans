import AppKit
import ScreenCaptureKit
import SnapTransCore

/// Captures a CG-global rectangle with ScreenCaptureKit at the display's native resolution. SnapTrans' own windows
/// (selection frame, result popup) are excluded; the Settings window is kept so it can be translated like any other.
enum ScreenCapture {
    /// Test hook: use this image instead of the screen (lets the pipeline run without Screen Recording).
    static var debugImage: CGImage? {
        guard let p = ProcessInfo.processInfo.environment["SNAPTRANS_DEBUG_IMAGE"],
              let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    @MainActor
    static func capture(_ rect: CGRect, keepWindows: [NSWindow]) async throws -> CGImage {
        if let img = debugImage { return img }
        // Never trigger the system prompt from a drag: explain first (Settings → macOS permissions) and let the user ask.
        guard Permissions.screenRecording else { throw SnapTransError("CaptureDenied") }
        guard let screen = Geometry.screen(forCG: rect) else { throw SnapTransError("CaptureFailed") }
        let displayID = Geometry.displayID(screen)
        let screenCG = Geometry.cg(fromAppKit: screen.frame)
        let clipped = rect.intersection(screenCG)
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { throw SnapTransError("CaptureFailed") }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw Permissions.screenRecording ? SnapTransError("CaptureFailed") : SnapTransError("CaptureDenied") }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw SnapTransError("CaptureFailed") }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let keepIDs = Set(keepWindows.filter { $0.isVisible }.map { CGWindowID($0.windowNumber) })
        let keep = content.windows.filter { keepIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: keep)
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        config.sourceRect = CGRect(x: clipped.minX - screenCG.minX, y: clipped.minY - screenCG.minY, width: clipped.width, height: clipped.height)
        config.width = Int((clipped.width * scale).rounded())
        config.height = Int((clipped.height * scale).rounded())
        config.scalesToFit = false
        config.showsCursor = false
        config.capturesAudio = false          // screen pixels only: no system audio
        config.captureMicrophone = false      // and never the microphone
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        do { return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) }
        catch { throw Permissions.screenRecording ? SnapTransError("CaptureFailed") : SnapTransError("CaptureDenied") }
    }
}
