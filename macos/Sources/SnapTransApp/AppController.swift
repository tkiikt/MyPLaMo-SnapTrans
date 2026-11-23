import AppKit
import Combine
import SnapTransCore
import SnapTransEngine
import SnapTransOCR

/// Menu bar app: owns the status item, the drag selection, the OCR/translation engines and the windows.
@MainActor
final class AppController: ObservableObject {
    static let showSettingsNotification = Notification.Name("io.github.tkiikt.MyPLaMo-SnapTrans.showSettings")
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    @Published var settings: AppSettings { didSet { if settings != oldValue { settings.save() } } }
    @Published private(set) var lastSource = ""
    @Published private(set) var lastTranslation = ""
    @Published private(set) var engineChanging = false
    @Published private(set) var verifying: Set<String> = []
    @Published private(set) var loaded: LoadedEngine?
    @Published private(set) var tapInstalled = false
    @Published private(set) var screenGranted = Permissions.screenRecording
    @Published private(set) var accessGranted = Permissions.accessibility
    @Published var hotKeyFailed = false
    @Published var revision = 0          // bumps when model files may have changed

    let translator = PlamoTranslator(locator: .bundled())
    let popup = PopupController()
    let overlay = SelectionOverlay()
    let input = SnapInput()
    let hotKey = HotKey()
    lazy var downloads = Downloads(app: self)
    var statusItem: StatusItemController?
    var settingsWindow: SettingsWindowController?
    private var job: Task<Void, Never>?
    private var permissionTimer: Timer?
    private var announcedFallback: String?
    private var exiting = false

    init() {
        VerificationCache.shared.filePath = AppSettings.home.appendingPathComponent("verify-cache.json")
        settings = AppSettings.load()
        Loc.current = Loc.resolve(settings.language)
        translator.diagnostic = { m in AppLog.log("engine: " + m) }
        translator.loading = { [weak self] backend in
            Task { @MainActor in self?.popup.setStage(Loc.f("Stage_Loading", backend == .metal ? "Metal" : "CPU")) }
        }
        configureTranslator()
    }

    // MARK: lifecycle

    func start() {
        AppLog.log("start \(Self.version) macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        applyTheme()
        statusItem = StatusItemController(app: self)
        input.onBegin = { [weak self] p in self?.selectionBegan(at: p) }
        input.onMove = { [weak self] p in self?.overlay.move(to: p) }
        input.onEnd = { [weak self] p in self?.selectionEnded(at: p) }
        input.onCancel = { [weak self] reason in AppLog.log("selection canceled: \(reason)"); self?.overlay.close() }
        applyInputSettings()
        HotKey.action = { [weak self] in self?.startInteractiveSelection() }
        applyHotKey()
        // Permissions can change in System Settings at any time; re-check while the app runs (cheap, no prompts).
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        let m = ModelInfo.find(settings.modelId)
        let state = m.map { ModelStore(folder: settings.modelFolder).state(of: $0) } ?? .missing
        if [.ready, .outdated, .unverified].contains(state) {
            Task { await ensureVerified(preload: true) }
        } else {
            openSettings()
        }
        if ProcessInfo.processInfo.environment["SNAPTRANS_OPEN_SETTINGS"] == "1" { openSettings() }
        AppLog.log("permissions: screen recording=\(screenGranted) accessibility=\(accessGranted) tap=\(tapInstalled)")
        DebugCommands.install(self)
        DistributedNotificationCenter.default().addObserver(forName: Self.showSettingsNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettings() }
        }
        Task.detached(priority: .utility) {
            let t0 = Date()
            await VisionOCR.prewarm()
            AppLog.log(String(format: "vision prewarm %.0fms", Date().timeIntervalSince(t0) * 1000))
        }
    }

    func quit() {
        guard !exiting else { return }
        exiting = true
        AppLog.log("exit requested")
        job?.cancel()
        input.uninstall()
        hotKey.unregister()
        overlay.close()
        popup.hide()
        lastSource = ""; lastTranslation = ""
        Task {
            await translator.shutdown()
            AppLog.log("exit complete")
            NSApp.terminate(nil)
        }
    }

    // MARK: settings application

    var japanese: Bool { Loc.japanese }

    func applyLanguage() {
        Loc.current = Loc.resolve(settings.language)
        statusItem?.refresh()
        objectWillChange.send()
        popup.model.objectWillChange.send()
    }

    var isDark: Bool {
        switch settings.theme {
        case "light": return false
        case "dark": return true
        default: return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    func applyTheme() {
        NSApp.appearance = settings.theme == "light" ? NSAppearance(named: .aqua) : settings.theme == "dark" ? NSAppearance(named: .darkAqua) : nil
        popup.applyTheme(dark: isDark)
    }

    func applyInputSettings() {
        input.modifiers = settings.modifiers.cgFlags
        input.enabled = settings.enabled
        if settings.enabled && !input.isInstalled && Permissions.accessibility {
            tapInstalled = input.install()
            AppLog.log("event tap: \(tapInstalled ? "installed" : "refused")")
        }
        tapInstalled = input.isInstalled
        statusItem?.refresh()
    }

    func applyHotKey() {
        hotKeyFailed = !hotKey.register(settings.hotKey)
        if hotKeyFailed { AppLog.log("hotkey: registration failed") }
    }

    func refreshPermissions() {
        let s = Permissions.screenRecording, a = Permissions.accessibility
        if s != screenGranted { screenGranted = s; AppLog.log("screen recording: \(s)") }
        if a != accessGranted { accessGranted = a; AppLog.log("accessibility: \(a)") }
        if a && settings.enabled && !input.isInstalled { applyInputSettings() }
    }

    // MARK: model / engine

    var store: ModelStore { ModelStore(folder: settings.modelFolder) }

    /// The selected model, only when its size and SHA-256 have been verified for this exact file.
    var activeModel: ModelInfo? {
        guard let m = ModelInfo.find(settings.modelId) else { return nil }
        let s = store.state(of: m)
        return s == .ready || s == .outdated ? m : nil
    }

    private var activeModelPath: String { activeModel.map { store.path(of: $0) } ?? "" }

    private func configureTranslator() {
        let m = activeModel
        let path = activeModelPath
        translator.configure(modelPath: path, selection: settings.device) { if let m { try ModelStore.guardModel(m, path: path) } }
    }

    /// Hashes the selected model once if it is new or changed (cached), then optionally preloads.
    func ensureVerified(preload: Bool) async {
        guard let m = ModelInfo.find(settings.modelId) else { return }
        let st = store
        if st.state(of: m) == .unverified && !verifying.contains(m.id) {
            verifying.insert(m.id)
            do { try await Task.detached { try await st.verify(m) }.value; AppLog.log("verified \(m.id)") }
            catch { AppLog.error("verify \(m.id)", error) }
            verifying.remove(m.id)
            revision += 1
            await applyEngineChange(nil, preload: preload)
            return
        }
        if preload { self.preload() }
    }

    func preload() {
        guard activeModel != nil, !exiting else { return }
        Task {
            do { try await translator.ensureLoaded() } catch is CancellationError {} catch { AppLog.error("preload", error) }
            loaded = translator.loaded
        }
    }

    /// Applies a device / model / folder change without blocking: running work is cancelled, the engine waits for it
    /// to leave, then restarts with the new configuration.
    func applyEngineChange(_ mutate: (() -> Void)?, preload: Bool = true) async {
        guard !exiting else { return }
        job?.cancel()
        mutate?()
        engineChanging = true
        await translator.reset()
        configureTranslator()
        engineChanging = false
        loaded = nil
        revision += 1
        if preload { self.preload() }
    }

    // MARK: selection → capture → OCR → translate

    private func selectionBegan(at p: CGPoint) {
        AppLog.log("selection: drag began (event tap)")
        job?.cancel()
        popup.hide()
        overlay.begin(at: p)
    }

    private func selectionEnded(at p: CGPoint) {
        overlay.move(to: p)
        let r = overlay.rect
        overlay.close()
        guard let r, r.width >= 6, r.height >= 6 else { AppLog.log("selection canceled: too small"); return }
        run(r)
    }

    func startInteractiveSelection() {
        guard !overlay.isInteractive else { return }
        AppLog.log("selection: Translate Area started")
        job?.cancel()
        popup.hide()
        overlay.startInteractive { [weak self] r in
            guard let self else { return }
            guard let r, r.width >= 6, r.height >= 6 else { AppLog.log("selection canceled"); return }
            self.run(r)
        }
    }

    func run(_ rect: CGRect) {
        guard !exiting else { return }
        job?.cancel()
        job = Task { await self.translate(rect) }
    }

    private func translate(_ rect: CGRect) async {
        let t0 = Date()
        popup.hide()   // never part of our own capture (also excluded by the capture filter)
        var original = ""
        AppLog.log("capture: start")
        do {
            let image = try await ScreenCapture.capture(rect, keepWindows: [settingsWindow?.window].compactMap { $0 })
            let tCapture = Date().timeIntervalSince(t0)
            try Task.checkCancellation()
            popup.show(at: rect, stage: Loc.t("Stage_Recognizing"))
            let lang = settings.ocrLanguage
            let ocr = try await Task.detached { try await VisionOCR.recognize(image, language: lang) }.value
            try Task.checkCancellation()
            original = ocr.text
            if original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                popup.setError(Loc.t("NoText"), source: ""); AppLog.log("no text recognized"); return
            }
            guard let model = activeModel else {
                // A selected file that has not been hashed yet (first use, or changed): verify it now, then try again.
                if let m = ModelInfo.find(settings.modelId), store.state(of: m) == .unverified, !verifying.contains(m.id) {
                    Task { await ensureVerified(preload: true) }
                }
                let key = verifying.contains(settings.modelId) || (ModelInfo.find(settings.modelId).map { store.state(of: $0) == .unverified } ?? false)
                    ? "Err_ModelVerifying" : "Err_NoModel"
                popup.setError(Loc.t(key), source: original)
                if key == "Err_NoModel" { openSettings() }
                return
            }
            popup.setStage(engineChanging ? Loc.t("Stage_Switching") : translator.loaded == nil ? Loc.f("Stage_Loading", "…") : Loc.t("Stage_Translating"))
            let to = LanguageGuess.resolveTarget(original, setting: settings.target)
            let tr = translator
            let text = original
            let result = try await Task.detached { try await tr.translate(text, to: to) }.value
            try Task.checkCancellation()
            loaded = translator.loaded
            lastSource = original; lastTranslation = result.text
            var note: String?
            if let reason = loaded?.fallbackReason {
                note = Loc.f("Fallback", Self.reasonText(reason))
                if announcedFallback != reason { announcedFallback = reason }
            }
            // Header shows the model size only; device and timing go to the log, warnings to an icon + tooltip.
            popup.setResult(translation: result.text, source: original, status: model.id.uppercased(), warning: note)
            AppLog.log(String(format: "capture=%.0fms ocr=%.0fms translate=%.0fms total=%.0fms backend=%@ chars=%d",
                              tCapture * 1000, ocr.elapsed * 1000, result.elapsed * 1000, Date().timeIntervalSince(t0) * 1000,
                              loaded?.backend.rawValue ?? "-", original.count))
        } catch is CancellationError {
        } catch let e as SnapTransError where e.code == "CaptureDenied" {
            AppLog.log("capture denied (screen recording not allowed)")
            popup.show(at: rect, stage: "")
            popup.setError(Loc.t("Err_CaptureDenied"), source: "")
            openSettings()
        } catch {
            if Task.isCancelled { return }
            AppLog.error("translate", error)
            popup.setError(Loc.error(error), source: original)
        }
    }

    static func reasonText(_ reason: String) -> String {
        let code = String(reason.split(separator: ":").first ?? "")
        let t = Loc.t("Err_" + code)
        return t == "Err_" + code ? reason : t
    }

    func showLast() {
        guard !lastTranslation.isEmpty else { openSettings(); return }
        let m = Geometry.cgPoint(fromAppKit: NSEvent.mouseLocation)
        popup.show(at: CGRect(x: m.x - 200, y: m.y - 10, width: 400, height: 10), stage: "")
        popup.setResult(translation: lastTranslation, source: lastSource, status: "", warning: nil)
    }

    func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(app: self) }
        settingsWindow?.show()
    }
}
