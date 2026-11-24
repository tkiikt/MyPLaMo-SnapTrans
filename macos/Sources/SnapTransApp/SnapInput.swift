import AppKit
import CoreGraphics

/// Global "modifier + left drag" through an active CGEventTap on its own thread. While a selection is in progress the
/// mouse-down/drag/up (and Esc) are swallowed so the application below never sees them. The tap callback only decides,
/// records points and hands them to the main thread. The mouse tap receives left-button events only; keyboard events
/// are received by a second tap that is enabled only while a drag is in progress (to see Esc) and disabled otherwise.
/// When drag-to-translate is turned off the taps are removed entirely (AppController.applyInputSettings).
final class SnapInput: @unchecked Sendable {
    var onBegin: ((CGPoint) -> Void)?
    var onMove: ((CGPoint) -> Void)?
    var onEnd: ((CGPoint) -> Void)?
    var onCancel: ((String) -> Void)?

    private let lock = NSLock()
    private var _modifiers: CGEventFlags = [.maskControl, .maskShift]
    private var _enabled = true
    var modifiers: CGEventFlags { get { lock.withLock { _modifiers } } set { lock.withLock { _modifiers = newValue } } }
    var enabled: Bool { get { lock.withLock { _enabled } } set { lock.withLock { _enabled = newValue } } }

    private var tap: CFMachPort?
    private var keyTap: CFMachPort?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var dragging = false        // tap thread only
    private var swallowUp = false       // tap thread only
    private(set) var isInstalled = false
    /// Diagnostics (counts only, under `lock`): left mouse-downs the tap saw, how many had the selected modifiers, tap re-enables.
    private var _seenDowns = 0, _matchedDowns = 0, _reenabled = 0
    var counters: (seenDowns: Int, matchedDowns: Int, reenabled: Int) { lock.withLock { (_seenDowns, _matchedDowns, _reenabled) } }

    static let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]

    /// Installs the taps; returns false when macOS refuses them (no Accessibility permission).
    @discardableResult
    func install() -> Bool {
        if isInstalled { return true }
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<SnapInput>.fromOpaque(refcon!).takeUnretainedValue()
            return me.handle(type, event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback, userInfo: refcon) else { return false }
        guard let keys = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: 1 << CGEventType.keyDown.rawValue, callback: callback, userInfo: refcon)
        else { CFMachPortInvalidate(port); return false }
        tap = port; keyTap = keys
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            guard let self, let tap = self.tap, let keyTap = self.keyTap else { ready.signal(); return }
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, keyTap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CGEvent.tapEnable(tap: keyTap, enable: false)   // only while dragging
            ready.signal()
            CFRunLoopRun()
        }
        t.name = "SnapInput"
        t.qualityOfService = .userInteractive
        t.start()
        ready.wait()
        thread = t
        isInstalled = true
        return true
    }

    func uninstall() {
        guard isInstalled else { return }
        for p in [tap, keyTap].compactMap({ $0 }) { CGEvent.tapEnable(tap: p, enable: false); CFMachPortInvalidate(p) }
        if let rl = runLoop { CFRunLoopStop(rl) }
        tap = nil; keyTap = nil; runLoop = nil; thread = nil; isInstalled = false
    }

    private func main(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }

    /// Tap thread only.
    private func setDragging(_ on: Bool) {
        dragging = on
        if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: on) }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            lock.withLock { _reenabled += 1 }
            if dragging { setDragging(false); swallowUp = true; main { self.onCancel?("tap disabled") } }
            return Unmanaged.passUnretained(event)
        case .leftMouseDown:
            let (mods, on) = lock.withLock { (_modifiers, _enabled) }
            let flags = event.flags.intersection(Self.relevant)
            let match = on && !mods.isEmpty && flags == mods
            lock.withLock { _seenDowns += 1; if match { _matchedDowns += 1 } }
            guard match else { return Unmanaged.passUnretained(event) }
            setDragging(true)
            let p = event.location
            main { self.onBegin?(p) }
            return nil
        case .leftMouseDragged:
            guard dragging else { return Unmanaged.passUnretained(event) }
            let p = event.location
            main { self.onMove?(p) }
            return nil
        case .leftMouseUp:
            if dragging {
                setDragging(false)
                let p = event.location
                main { self.onEnd?(p) }
                return nil
            }
            if swallowUp { swallowUp = false; return nil }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            // Only reached while dragging (the keyboard tap is disabled otherwise); only the Esc key code is read.
            if dragging && event.getIntegerValueField(.keyboardEventKeycode) == 53 /* Esc */ {
                setDragging(false); swallowUp = true
                main { self.onCancel?("esc") }
                return nil
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

/// Other processes with an active (filtering) event tap on left mouse-down: they may consume a drag before SnapTrans.
enum TapConflicts {
    static func others() -> [String] {
        var n: UInt32 = 0
        guard CGGetEventTapList(0, nil, &n) == .success, n > 0 else { return [] }
        var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(n))
        guard CGGetEventTapList(n, &list, &n) == .success else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var names: [String] = []
        for t in list.prefix(Int(n)) where t.enabled && t.options != .listenOnly && t.tappingProcess != me
            && t.eventsOfInterest & (1 << CGEventType.leftMouseDown.rawValue) != 0 {
            let name = NSRunningApplication(processIdentifier: t.tappingProcess)?.localizedName ?? "pid \(t.tappingProcess)"
            if !names.contains(name) { names.append(name) }
        }
        return names
    }
}
