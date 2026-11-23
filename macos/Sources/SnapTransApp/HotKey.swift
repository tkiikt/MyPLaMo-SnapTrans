import Carbon.HIToolbox
import Foundation

/// A system-wide shortcut through RegisterEventHotKey (no permission needed).
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handlerInstalled = false
    nonisolated(unsafe) static var action: (() -> Void)?

    static func carbonModifiers(_ m: SnapModifiers) -> UInt32 {
        var r: UInt32 = 0
        if m.contains(.control) { r |= UInt32(controlKey) }
        if m.contains(.option) { r |= UInt32(optionKey) }
        if m.contains(.shift) { r |= UInt32(shiftKey) }
        if m.contains(.command) { r |= UInt32(cmdKey) }
        return r
    }

    /// Returns false when the combination is taken (or invalid).
    func register(_ spec: HotKeySpec?) -> Bool {
        unregister()
        guard let spec else { return true }
        if !Self.handlerInstalled {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.action?() }
                return noErr
            }, 1, &type, nil, nil)
            Self.handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x534E_5054 /* SNPT */), id: 1)
        let status = RegisterEventHotKey(spec.keyCode, Self.carbonModifiers(spec.modifiers), id, GetApplicationEventTarget(), 0, &ref)
        return status == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}
