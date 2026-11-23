import AppKit

/// All coordinate conversion in one place.
///  - "CG global": Quartz display space used by CGEvent and ScreenCaptureKit; origin at the top-left of the main
///    (menu bar) display, y grows downwards, units are points.
///  - "AppKit": NSWindow / NSScreen frames; origin at the bottom-left of the main display, y grows upwards, points.
///  - "Display local": points relative to one display's top-left (SCStreamConfiguration.sourceRect).
///  - Pixels = points × that display's backingScaleFactor (Retina: 2).
enum Geometry {
    static var mainHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func appKit(fromCG r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }

    static func cg(fromAppKit r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }

    static func cgPoint(fromAppKit p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: mainHeight - p.y) }

    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    /// The screen that contains most of a CG-global rectangle (or the one nearest to its centre).
    static func screen(forCG r: CGRect) -> NSScreen? {
        let a = appKit(fromCG: r)
        var best: (NSScreen, CGFloat)?
        for s in NSScreen.screens {
            let i = s.frame.intersection(a)
            let area = i.isNull ? 0 : i.width * i.height
            if area > (best?.1 ?? -1) { best = (s, area) }
        }
        if let b = best, b.1 > 0 { return b.0 }
        let c = NSPoint(x: a.midX, y: a.midY)
        return NSScreen.screens.min { hypot($0.frame.midX - c.x, $0.frame.midY - c.y) < hypot($1.frame.midX - c.x, $1.frame.midY - c.y) }
    }

    /// Rectangle from two CG-global points, normalised.
    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
