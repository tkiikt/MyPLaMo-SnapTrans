import AppKit
import SnapTransCore

/// Model downloads (live independently of the Settings window). Explicit user actions only.
@MainActor
final class Downloads: ObservableObject {
    @Published var progress: [String: DownloadProgress] = [:]
    @Published var message = ""
    private var tasks: [String: Task<Void, Never>] = [:]
    unowned let app: AppController

    init(app: AppController) { self.app = app }

    func isRunning(_ id: String) -> Bool { tasks[id] != nil }

    func confirm(_ title: String, _ body: String, _ ok: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.addButton(withTitle: ok)
        a.addButton(withTitle: Loc.t("Cancel"))
        return a.runModal() == .alertFirstButtonReturn
    }

    func start(_ m: ModelInfo) {
        guard app.settings.licenseAccepted else { message = Loc.t("License_Required"); return }
        let store = app.store
        let before = store.state(of: m)
        let key = before == .corrupt ? "Confirm_Redownload" : before == .outdated ? "Confirm_Update" : "Confirm_Download"
        guard confirm(Loc.f(key + "_Title", m.displayName), Loc.f(key + "_Body", store.folder, Loc.size(m.bytes)), Loc.t(before == .outdated ? "Model_Update" : "Model_Download")) else { return }
        if before == .corrupt {
            if app.settings.modelId == m.id { Task { await app.applyEngineChange(nil, preload: false) } }
            try? store.delete(m)
        }
        message = ""
        tasks[m.id] = Task {
            do {
                try await Task.detached {
                    try await store.download(m, replaceExisting: before == .outdated) { p in
                        Task { @MainActor [weak self] in self?.progress[m.id] = p }
                    }
                }.value
                message = Loc.f("Model_Downloaded", m.displayName)
                AppLog.log("downloaded \(m.id)")
                if app.settings.modelId.isEmpty || app.settings.modelId == m.id || app.activeModel == nil {
                    await app.applyEngineChange { self.app.settings.modelId = m.id }
                }
            } catch is CancellationError {
                message = Loc.t("Model_Paused")
            } catch let e as URLError where e.code == .cancelled {
                message = Loc.t("Model_Paused")
            } catch {
                AppLog.error("download \(m.id)", error)
                message = Loc.error(error)
            }
            tasks[m.id] = nil
            progress[m.id] = nil
            app.revision += 1
        }
    }

    func pause(_ m: ModelInfo) { tasks[m.id]?.cancel() }

    func delete(_ m: ModelInfo) {
        let store = app.store
        guard confirm(Loc.f("Model_DeleteConfirm", m.displayName), Loc.f("Confirm_Delete_Body", store.path(of: m)), Loc.t("Model_Delete")) else { return }
        Task {
            if app.settings.modelId == m.id { await app.applyEngineChange({ self.app.settings.modelId = "" }, preload: false) }
            do { try store.delete(m); message = Loc.f("Model_Deleted", m.displayName); AppLog.log("deleted \(m.id)") }
            catch { message = Loc.error(error) }
            app.revision += 1
        }
    }

    func use(_ m: ModelInfo) {
        Task {
            await app.applyEngineChange { self.app.settings.modelId = m.id }
            if app.store.state(of: m) == .unverified { await app.ensureVerified(preload: true) }
            message = Loc.f("Model_Selected", m.displayName)
        }
    }
}
