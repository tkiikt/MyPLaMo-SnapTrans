import AppKit
import SnapTransCore
import SnapTransEngine
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    init(app: AppController) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = Loc.t("Settings_Title")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 480)
        window.contentView = NSHostingView(rootView: SettingsView(app: app, downloads: app.downloads))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("SnapTransSettings")
    }

    func show() {
        window.title = Loc.t("Settings_Title")
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
    }
}

struct Note: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View { Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

struct StatusBadge: View {
    let ok: Bool
    let text: String
    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(ok ? Color.green : Color.orange)
    }
}

struct SettingsView: View {
    @ObservedObject var app: AppController
    @ObservedObject var downloads: Downloads
    @State private var recording = false
    @State private var recorder: Any?

    var body: some View {
        let _ = app.revision
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                modelCard.id("model")
                deviceCard.id("device")
                shortcutCard.id("shortcut")
                permissionsCard.id("permissions")
                translationCard.id("translation")
                ocrCard.id("ocr")
                appearanceCard.id("appearance")
                lastCard.id("last")
                aboutCard.id("about")
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { DebugCommands.scrollRequest = { id in withAnimation { proxy.scrollTo(id, anchor: .top) } } }
        }
        .environment(\.locale, Locale(identifier: Loc.current))
    }

    var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Loc.t("Settings_Title")).font(.system(size: 22, weight: .bold))
                Note(Loc.t("Settings_Subtitle"))
            }
            Spacer()
            Text(Loc.t("BuiltWithPlamo"))
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor))
                .accessibilityIdentifier("BuiltWithPlamo")
        }
    }

    // MARK: model

    var modelCard: some View {
        Card(title: Loc.t("Sec_Model")) {
            Note(Loc.t("Model_Desc"))
            ForEach(ModelInfo.catalog) { m in modelRow(m) }
            if !downloads.message.isEmpty { Text(downloads.message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack(spacing: 8) {
                Text(Loc.t("Folder")).font(.system(size: 12, weight: .medium))
                Text(app.settings.modelFolder).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled).help(app.settings.modelFolder)
                Spacer()
                Button(Loc.t("Folder_Change")) { pickFolder() }
                Button(Loc.t("Folder_Open")) { openFolder() }
                if app.settings.modelFolder != AppSettings.defaultModelFolder {
                    Button(Loc.t("Folder_Default")) { setFolder(AppSettings.defaultModelFolder) }
                }
            }
            Note(Loc.t("Folder_Note"))
            Divider()
            Link(Loc.t("License_Link"), destination: Loc.licenseURL).font(.system(size: 12))
            Toggle(Loc.t("License_Agree"), isOn: Binding(get: { app.settings.licenseAccepted }, set: { app.settings.licenseAccepted = $0 }))
                .toggleStyle(.checkbox).font(.system(size: 12))
        }
    }

    func modelRow(_ m: ModelInfo) -> some View {
        let store = app.store
        let state = store.state(of: m)
        let inUse = app.settings.modelId == m.id
        let running = downloads.isRunning(m.id)
        let verifying = app.verifying.contains(m.id)
        var status: String
        switch state {
        case .missing: status = Loc.t("Model_Missing")
        case .partial: status = Loc.f("Model_Partial", Loc.size(store.partialBytes(of: m)))
        case .unverified: status = verifying ? Loc.t("Model_VerifyingExisting") : Loc.t("Model_Unverified")
        case .corrupt: status = Loc.t("Model_Corrupt")
        case .ready: status = inUse ? Loc.t("Model_InUse") : Loc.t("Model_Ready")
        case .outdated: status = Loc.f("Model_Outdated", store.version(of: m)?.date ?? "?") + (inUse ? " · " + Loc.t("Model_InUse") : "")
        }
        if m.id == "8b" { status += " · " + Loc.t("Model_Large") }
        if m.id == "31b" { status += " · " + Loc.t("Model_Huge") }
        let p = downloads.progress[m.id]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: inUse && (state == .ready || state == .outdated) ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(inUse ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(m.displayName).font(.system(size: 13, weight: .semibold))
                        Text(Loc.size(m.bytes)).font(.system(size: 12)).foregroundStyle(.secondary)
                        Link(destination: m.repositoryURL) { Image(systemName: "arrow.up.right.square").font(.system(size: 11)) }.help(m.repositoryURL.absoluteString)
                    }
                    Text(status).font(.system(size: 12)).foregroundStyle(state == .corrupt ? Color.red : .secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if running {
                    Button(Loc.t("Model_Cancel")) { downloads.pause(m) }
                } else {
                    switch state {
                    case .missing: Button(Loc.t("Model_Download")) { downloads.start(m) }
                    case .partial: Button(Loc.t("Model_Resume")) { downloads.start(m) }; Button(Loc.t("Model_Delete")) { downloads.delete(m) }
                    case .corrupt: Button(Loc.t("Model_Redownload")) { downloads.start(m) }; Button(Loc.t("Model_Delete")) { downloads.delete(m) }
                    case .ready, .outdated, .unverified:
                        if state == .outdated { Button(Loc.t("Model_Update")) { downloads.start(m) } }
                        if !inUse { Button(Loc.t("Model_Use")) { downloads.use(m) }.disabled(app.engineChanging) }
                        Button(Loc.t("Model_Delete")) { downloads.delete(m) }
                    }
                }
            }
            if let p {
                ProgressView(value: p.phase == .connecting ? nil : p.fraction).progressViewStyle(.linear)
                Text(progressText(p)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
        .accessibilityIdentifier("model-\(m.id)")
    }

    func progressText(_ p: DownloadProgress) -> String {
        switch p.phase {
        case .connecting: return Loc.t("Model_Connecting")
        case .verifying: return Loc.t("Model_Verifying") + String(format: "　%.0f%%", p.fraction * 100)
        case .done: return ""
        case .downloading: return Loc.f("Model_Progress", Loc.t("Model_Download"), p.fraction * 100, Loc.size(p.received), Loc.size(p.total), p.bytesPerSecond / 1e6)
        }
    }

    func setFolder(_ path: String) {
        guard path != app.settings.modelFolder else { return }
        Task { await app.applyEngineChange { app.settings.modelFolder = path }; await app.ensureVerified(preload: true) }
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = Loc.t("Folder_Pick")
        panel.directoryURL = URL(fileURLWithPath: app.settings.modelFolder)
        if panel.runModal() == .OK, let url = panel.url { setFolder(url.path) }
    }

    func openFolder() {
        try? FileManager.default.createDirectory(atPath: app.settings.modelFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: app.settings.modelFolder, isDirectory: true))
    }

    // MARK: device

    var deviceCard: some View {
        Card(title: Loc.t("Sec_Device")) {
            Note(Loc.t("Device_Desc"))
            Picker("", selection: Binding(get: { app.settings.device }, set: { v in Task { await app.applyEngineChange { app.settings.device = v } } })) {
                Text(Loc.t("Device_Auto")).tag("auto")
                Text(Loc.t("Device_Cpu")).tag("cpu")
            }
            .pickerStyle(.radioGroup).labelsHidden().disabled(app.engineChanging)
            if let l = app.loaded {
                let name = l.backend == .metal ? "Metal (\(Self.gpuName))" : "CPU"
                Text(Loc.f("Device_Current", Loc.f("Device_Loaded", name, l.loadTime))).font(.system(size: 12))
                if let r = l.fallbackReason { Text(Loc.f("Fallback", AppController.reasonText(r))).font(.system(size: 12)).foregroundStyle(.orange) }
            } else {
                Text(Loc.t("Device_NotLoaded")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    static let gpuName: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }()

    // MARK: shortcut

    var shortcutCard: some View {
        Card(title: Loc.t("Sec_Shortcut")) {
            Toggle(Loc.t("Shortcut_Enabled"), isOn: Binding(get: { app.settings.enabled }, set: { app.settings.enabled = $0; app.applyInputSettings() }))
            Note(Loc.t("Shortcut_Desc"))
            HStack(spacing: 14) {
                modToggle("⌃ Control", .control)
                modToggle("⌥ Option", .option)
                modToggle("⇧ Shift", .shift)
                modToggle("⌘ Command", .command)
            }
            let conflicts = TapConflicts.others()
            if !conflicts.isEmpty { Text(Loc.f("Tap_Conflict", conflicts.joined(separator: ", "))).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            Note(Loc.t("Shortcut_Remote"))
            if app.settings.modifiers.isEmpty { Text(Loc.t("Shortcut_Need")).font(.system(size: 12)).foregroundStyle(.orange) }
            Text(app.settings.enabled ? (app.tapInstalled ? Loc.t("Tap_Active") : Loc.t("Tap_Inactive")) : Loc.t("Tap_Disabled"))
                .font(.system(size: 12)).foregroundStyle(app.tapInstalled || !app.settings.enabled ? Color.secondary : Color.orange)
            Divider()
            HStack(spacing: 10) {
                Text(Loc.t("Hotkey")).font(.system(size: 13))
                Text(recording ? Loc.t("Hotkey_Recording") : (app.settings.hotKey?.display ?? Loc.t("Hotkey_None")))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                Spacer()
                Button(Loc.t("Hotkey_Record")) { startRecording() }.disabled(recording)
                Button(Loc.t("Hotkey_Clear")) { app.settings.hotKey = nil; app.applyHotKey() }.disabled(app.settings.hotKey == nil)
            }
            if app.hotKeyFailed { Text(Loc.t("Hotkey_Failed")).font(.system(size: 12)).foregroundStyle(.orange) }
            Note(Loc.t("Hotkey_Desc"))
        }
    }

    func modToggle(_ label: String, _ m: SnapModifiers) -> some View {
        Toggle(label, isOn: Binding(get: { app.settings.modifiers.contains(m) }, set: { on in
            var s = app.settings.modifiers
            if on { s.insert(m) } else { s.remove(m) }
            app.settings.modifiers = s
            app.applyInputSettings()
        })).toggleStyle(.checkbox)
    }

    func startRecording() {
        recording = true
        app.hotKey.unregister()
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            defer { if let r = recorder { NSEvent.removeMonitor(r) }; recorder = nil; recording = false }
            if e.keyCode == 53 { app.applyHotKey(); return nil }
            var mods: SnapModifiers = []
            if e.modifierFlags.contains(.control) { mods.insert(.control) }
            if e.modifierFlags.contains(.option) { mods.insert(.option) }
            if e.modifierFlags.contains(.shift) { mods.insert(.shift) }
            if e.modifierFlags.contains(.command) { mods.insert(.command) }
            guard !mods.isEmpty, let label = e.charactersIgnoringModifiers?.uppercased(), !label.isEmpty else { app.applyHotKey(); return nil }
            app.settings.hotKey = HotKeySpec(keyCode: UInt32(e.keyCode), modifiers: mods, keyLabel: label)
            app.applyHotKey()
            return nil
        }
    }

    // MARK: permissions

    var permissionsCard: some View {
        Card(title: Loc.t("Sec_Permissions")) {
            Note(Loc.t("Perm_Desc"))
            permissionRow(Loc.t("Perm_Screen"), app.screenGranted, id: "perm-screen",
                          request: { Permissions.requestScreenRecording(); app.refreshPermissions() },
                          open: Permissions.openScreenRecordingSettings)
            if !app.screenGranted { Note(Loc.t("Perm_ScreenNeeded")) }
            permissionRow(Loc.t("Perm_Access"), app.accessGranted, id: "perm-access",
                          request: { Permissions.requestAccessibility() },
                          open: Permissions.openAccessibilitySettings)
            if !app.accessGranted { Note(Loc.t("Perm_AccessNote")) }
            Note(Loc.t("Perm_Restart"))
        }
    }

    func permissionRow(_ title: String, _ ok: Bool, id: String, request: @escaping () -> Void, open: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 13))
            Spacer()
            StatusBadge(ok: ok, text: Loc.t(ok ? "Perm_Granted" : "Perm_NotGranted")).accessibilityIdentifier(id)
            if !ok { Button(Loc.t("Perm_Request"), action: request) }
            Button(Loc.t("Perm_Open"), action: open)
        }
    }

    // MARK: translation / OCR / appearance

    var translationCard: some View {
        Card(title: Loc.t("Sec_Translation")) {
            Picker(Loc.t("Target"), selection: Binding(get: { app.settings.target }, set: { app.settings.target = $0 })) {
                Text(Loc.t("Target_Auto")).tag("auto")
                Divider()
                ForEach(TranslationLanguage.all) { l in Text(l.name(japaneseUI: Loc.japanese)).tag(l.id) }
            }.frame(maxWidth: 420)
            Note(Loc.t("Target_Desc"))
        }
    }

    var ocrCard: some View {
        Card(title: Loc.t("Sec_Ocr")) {
            Picker(Loc.t("Ocr_Language"), selection: Binding(get: { app.settings.ocrLanguage }, set: { app.settings.ocrLanguage = $0 })) {
                Text(Loc.t("Ocr_Auto")).tag("")
                Text(Loc.t("Ocr_Ja")).tag("ja")
                Text(Loc.t("Ocr_En")).tag("en")
            }.frame(maxWidth: 420)
            Note(Loc.t("Ocr_Desc"))
        }
    }

    var appearanceCard: some View {
        Card(title: Loc.t("Sec_Appearance")) {
            Picker(Loc.t("UiLanguage"), selection: Binding(get: { app.settings.language }, set: { app.settings.language = $0; app.applyLanguage() })) {
                Text(Loc.t("UiLanguage_Auto")).tag("auto")
                Text("日本語").tag("ja-JP")
                Text("English").tag("en-US")
            }.frame(maxWidth: 420)
            Picker(Loc.t("Theme"), selection: Binding(get: { app.settings.theme }, set: { app.settings.theme = $0; app.applyTheme() })) {
                Text(Loc.t("Theme_System")).tag("system")
                Text(Loc.t("Theme_Light")).tag("light")
                Text(Loc.t("Theme_Dark")).tag("dark")
            }.frame(maxWidth: 420)
        }
    }

    var lastCard: some View {
        Card(title: Loc.t("Sec_Last")) {
            if app.lastTranslation.isEmpty { Note(Loc.t("Last_None")) }
            else {
                Text(Loc.t("Last_Source")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Text(app.lastSource).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(Loc.t("Last_Result")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Text(app.lastTranslation).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var aboutCard: some View {
        Card(title: Loc.t("Sec_About")) {
            Text(Loc.f("About_Text", AppController.version, "b12121")).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Link(Loc.t("License_Link"), destination: Loc.licenseURL)
                Link("llama.cpp", destination: URL(string: "https://github.com/ggml-org/llama.cpp")!)
            }.font(.system(size: 12))
        }
    }
}
