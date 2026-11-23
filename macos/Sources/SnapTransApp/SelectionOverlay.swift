import AppKit

/// One transparent, top-most, click-through overlay per display that draws the selection frame. The frame is excluded
/// from screen capture (sharingType = .none) so it never ends up in the OCR image; SNAPTRANS_SHOW_IN_CAPTURE=1 makes it
/// visible to screenshots for documentation. In interactive mode (menu "Translate Area" / shortcut) the overlays take
/// the mouse themselves, show a crosshair and a hint, and Esc cancels.
@MainActor
final class SelectionOverlay {
    final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    final class FrameView: NSView {
        var selection: NSRect?      // in this window's coordinates
        var interactive = false
        var hint = ""
        weak var owner: SelectionOverlay?
        override var isFlipped: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            if interactive {
                NSColor.black.withAlphaComponent(0.18).setFill()
                bounds.fill()
            }
            if let r = selection, r.width > 0 || r.height > 0 {
                if interactive { NSColor.clear.setFill(); r.fill(using: .copy) }
                NSColor(srgbRed: 0.30, green: 0.76, blue: 1.0, alpha: 0.10).setFill()
                r.fill(using: .sourceOver)
                let outer = NSBezierPath(rect: r.insetBy(dx: -1.5, dy: -1.5)); outer.lineWidth = 1
                NSColor.black.withAlphaComponent(0.55).setStroke(); outer.stroke()
                let inner = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)); inner.lineWidth = 2
                NSColor(srgbRed: 0.30, green: 0.76, blue: 1.0, alpha: 1).setStroke(); inner.stroke()
            }
            if interactive && !hint.isEmpty && selection == nil {
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white]
                let s = NSAttributedString(string: hint, attributes: attrs)
                let size = s.size()
                let box = NSRect(x: bounds.midX - size.width / 2 - 16, y: bounds.maxY - 120, width: size.width + 32, height: size.height + 16)
                NSColor(srgbRed: 0.153, green: 0.196, blue: 0.259, alpha: 0.92).setFill()
                NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
                s.draw(at: NSPoint(x: box.minX + 16, y: box.minY + 8))
            }
        }

        override func resetCursorRects() { if interactive { addCursorRect(bounds, cursor: .crosshair) } }
        override func mouseDown(with e: NSEvent) { owner?.interactiveDown(e) }
        override func mouseDragged(with e: NSEvent) { owner?.interactiveDrag(e) }
        override func mouseUp(with e: NSEvent) { owner?.interactiveUp(e) }
        override func rightMouseDown(with e: NSEvent) { owner?.finishInteractive(nil) }
        override func keyDown(with e: NSEvent) { if e.keyCode == 53 { owner?.finishInteractive(nil) } }
    }

    private var windows: [Panel] = []
    private var start: CGPoint?
    private var current: CGPoint?
    private var interactiveCompletion: ((CGRect?) -> Void)?
    private var escMonitor: Any?
    static var visibleToCapture: Bool { ProcessInfo.processInfo.environment["SNAPTRANS_SHOW_IN_CAPTURE"] == "1" }
    var isActive: Bool { !windows.isEmpty }
    var isInteractive: Bool { interactiveCompletion != nil }

    private func buildWindows(interactive: Bool) {
        close()
        for screen in NSScreen.screens {
            let w = Panel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.ignoresMouseEvents = !interactive
            w.sharingType = Self.visibleToCapture ? .readOnly : .none
            w.isReleasedWhenClosed = false
            w.hidesOnDeactivate = false
            w.title = "SnapTrans Selection"
            let v = FrameView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.interactive = interactive
            v.hint = Loc.t("Select_Hint")
            v.owner = self
            w.contentView = v
            w.setFrame(screen.frame, display: false)
            w.orderFrontRegardless()
            windows.append(w)
        }
    }

    /// Passive frame driven by the event tap (CG-global points).
    func begin(at p: CGPoint) {
        buildWindows(interactive: false)
        start = p; current = p
        redraw()
    }

    func move(to p: CGPoint) { guard start != nil else { return }; current = p; redraw() }

    /// Selected rectangle (CG global) so far.
    var rect: CGRect? { guard let s = start, let c = current else { return nil }; return Geometry.rect(s, c) }

    func close() {
        for w in windows { w.orderOut(nil); w.close() }
        windows.removeAll()
        start = nil; current = nil
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
    }

    private func redraw() {
        let r = rect.map { Geometry.appKit(fromCG: $0) }
        for w in windows {
            guard let v = w.contentView as? FrameView else { continue }
            if let r {
                let local = NSRect(x: r.minX - w.frame.minX, y: r.minY - w.frame.minY, width: r.width, height: r.height)
                v.selection = local.intersects(v.bounds) ? local : NSRect(x: -10, y: -10, width: 0, height: 0)
            } else { v.selection = nil }
            v.needsDisplay = true
        }
    }

    // MARK: interactive mode

    func startInteractive(_ completion: @escaping (CGRect?) -> Void) {
        buildWindows(interactive: true)
        interactiveCompletion = completion
        // Key status (without activating the app) so Esc reaches the overlay; a local monitor covers the rest.
        let mouse = NSEvent.mouseLocation
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKey()
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.finishInteractive(nil); return nil }
            return e
        }
        NSCursor.crosshair.set()
    }

    private func point(_ e: NSEvent) -> CGPoint {
        let p = e.window?.convertPoint(toScreen: e.locationInWindow) ?? NSEvent.mouseLocation
        return Geometry.cgPoint(fromAppKit: p)
    }

    func interactiveDown(_ e: NSEvent) { start = point(e); current = start; redraw() }
    func interactiveDrag(_ e: NSEvent) { if start == nil { start = point(e) }; current = point(e); redraw() }
    func interactiveUp(_ e: NSEvent) { current = point(e); finishInteractive(rect) }

    /// Test hook (DebugCommands): routes synthetic mouse events through the overlay window under the start point.
    func debugDrag(from a: CGPoint, to b: CGPoint) {
        let pa = NSPoint(x: a.x, y: Geometry.mainHeight - a.y), pb = NSPoint(x: b.x, y: Geometry.mainHeight - b.y)
        guard let w = windows.first(where: { $0.frame.contains(pa) }) else { return }
        func ev(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: w.convertPoint(fromScreen: p), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let e = ev(.leftMouseDown, pa) { w.sendEvent(e) }
        for i in 1...10 {
            let t = CGFloat(i) / 10
            if let e = ev(.leftMouseDragged, NSPoint(x: pa.x + (pb.x - pa.x) * t, y: pa.y + (pb.y - pa.y) * t)) { w.sendEvent(e) }
        }
        if let e = ev(.leftMouseUp, pb) { w.sendEvent(e) }
    }

    func finishInteractive(_ r: CGRect?) {
        let done = interactiveCompletion
        interactiveCompletion = nil
        close()
        NSCursor.arrow.set()
        done?(r)
    }
}
