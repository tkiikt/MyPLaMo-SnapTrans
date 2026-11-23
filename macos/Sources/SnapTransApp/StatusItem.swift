import AppKit

/// Menu bar item: left click opens Settings, right click (or Control-click) shows the menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    // F design (assets/icon/tray-*.svg): frame corners + blue speech bubble, one variant per menu bar appearance.
    static let lightSVG = #"""
<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
  <title>SnapTrans tray – F, light taskbar</title>
  <defs><mask id="m"><rect width="16" height="16" fill="#fff"/><rect x="6" y="6.5" width="4" height="1.5" fill="#000"/></mask></defs>
  <g fill="none" stroke="#1b1b1b" stroke-width="1.5" stroke-linecap="square">
    <path d="M1.75 5V1.75H5"/><path d="M11 1.75H14.25V5"/><path d="M14.25 11V14.25H11"/><path d="M5 14.25H1.75V11"/>
  </g>
  <g fill="#0a74c4" mask="url(#m)">
    <rect x="4" y="4" width="8" height="6" rx="1.5"/>
    <path d="M5 9V12.5L8.5 9.5Z"/>
  </g>
</svg>
"""#
    static let darkSVG = #"""
<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
  <title>SnapTrans tray – F, dark taskbar</title>
  <defs><mask id="m"><rect width="16" height="16" fill="#fff"/><rect x="6" y="6.5" width="4" height="1.5" fill="#000"/></mask></defs>
  <g fill="none" stroke="#ffffff" stroke-width="1.5" stroke-linecap="square">
    <path d="M1.75 5V1.75H5"/><path d="M11 1.75H14.25V5"/><path d="M14.25 11V14.25H11"/><path d="M5 14.25H1.75V11"/>
  </g>
  <g fill="#4cc2ff" mask="url(#m)">
    <rect x="4" y="4" width="8" height="6" rx="1.5"/>
    <path d="M5 9V12.5L8.5 9.5Z"/>
  </g>
</svg>
"""#

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private weak var app: AppController?
    private var appearanceObservation: NSKeyValueObservation?

    init(app: AppController) {
        self.app = app
        super.init()
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityTitle("MyPLaMo SnapTrans")
        appearanceObservation = button.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateIcon() }
        }
        refresh()
    }

    private var iconIsDark: Bool?

    private func updateIcon() {
        guard let button = item.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // Setting the image re-triggers the effectiveAppearance observation: only act on a real change (no loop).
        if dark == iconIsDark { return }
        iconIsDark = dark
        let img = NSImage(data: Data((dark ? Self.darkSVG : Self.lightSVG).utf8))
        img?.size = NSSize(width: 18, height: 18)
        img?.isTemplate = false
        button.image = img
    }

    func refresh() {
        guard let app else { return }
        item.button?.toolTip = Loc.f("Tip", app.settings.modifiers.text)
    }

    @objc private func clicked(_ sender: Any?) {
        guard let app else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true { showMenu() }
        else { app.openSettings() }
    }

    func showMenu() {
        guard let app else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, key: String = "", state: Bool? = nil) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            if let state { i.state = state ? .on : .off }
            menu.addItem(i)
        }
        add(Loc.t("Menu_Select"), #selector(select))
        if let hk = app.settings.hotKey, let last = menu.items.last {
            last.keyEquivalent = hk.keyLabel.lowercased()
            last.keyEquivalentModifierMask = NSEvent.ModifierFlags(snap: hk.modifiers)
        }
        add(Loc.t("Menu_Last"), #selector(last))
        menu.items.last?.isEnabled = !app.lastTranslation.isEmpty
        add(Loc.t("Menu_Enabled"), #selector(toggleEnabled), state: app.settings.enabled)
        menu.addItem(.separator())
        add(Loc.t("Menu_Settings"), #selector(settings), key: ",")
        menu.addItem(.separator())
        add(Loc.t("Menu_Quit"), #selector(quit), key: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func select() { app?.startInteractiveSelection() }
    @objc private func last() { app?.showLast() }
    @objc private func settings() { app?.openSettings() }
    @objc private func quit() { app?.quit() }
    @objc private func toggleEnabled() {
        guard let app else { return }
        app.settings.enabled.toggle()
        app.applyInputSettings()
    }
}

extension NSEvent.ModifierFlags {
    init(snap m: SnapModifiers) {
        self = []
        if m.contains(.control) { insert(.control) }
        if m.contains(.option) { insert(.option) }
        if m.contains(.shift) { insert(.shift) }
        if m.contains(.command) { insert(.command) }
    }
}
