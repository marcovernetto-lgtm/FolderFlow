import Foundation
import Combine

@MainActor
final class CatalogWorkspace: ObservableObject {
    @Published private(set) var archive = CatalogArchive()
    @Published private(set) var ownerID: String?
    @Published private(set) var syncing = false
    @Published private(set) var readOnly = false
    @Published var errorMessage: String?
    private let manager: DataManager
    let cloud: CloudService
    let onlineBackups: CloudBackupService
    private let files: CatalogArchiveFile
    let deviceID: String
    private var subscriptions = Set<AnyCancellable>()
    private var retry: Timer?
    private var applying = false
    private var scheduledSync: Task<Void, Never>?
    private var lastSynchronizationError: String?
    private var guestPreferences: SharedAppPreferences

    var preferences: SharedAppPreferences { archive.preferences ?? guestPreferences }
    var active: StoredCatalog? { archive.catalogs.first { $0.id == archive.activeCatalogID } }
    var status: String {
        if readOnly { return "Errore nel salvataggio locale" }
        if !archive.conflicts.isEmpty { return "\(archive.conflicts.count) conflitti da risolvere" }
        if ownerID == nil { return "Su questo Mac" }
        if cloud.errorMessage != nil { return "Cloud da verificare" }
        if !cloud.online { return "Offline · \(archive.pending.count) modifiche in attesa" }
        if syncing { return "Sincronizzazione…" }
        if !archive.pending.isEmpty { return "\(archive.pending.count) modifiche in attesa" }
        return "Cataloghi aggiornati"
    }

    init(manager: DataManager, cloud: CloudService, root: URL? = nil, deviceID: String? = nil) {
        self.manager = manager; self.cloud = cloud
        self.onlineBackups = CloudBackupService(cloud: cloud)
        self.guestPreferences = manager.appPreferences
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        files = CatalogArchiveFile(root: root ?? support.appendingPathComponent("FolderFlow/Catalogs", isDirectory: true))
        if let deviceID { self.deviceID = deviceID }
        else {
            let saved = UserDefaults.standard.string(forKey: "FolderFlowDeviceID") ?? UUID().uuidString
            UserDefaults.standard.set(saved, forKey: "FolderFlowDeviceID")
            self.deviceID = saved
        }
        onlineBackups.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        if let local = try? files.load(owner: nil), let preferences = local.preferences { guestPreferences = preferences }
        openProfile(cloud.user?.id, migrateLegacy: true)
        manager.attachCatalogPersistence { [weak self] in self?.capture() }
        manager.catalogExport = { [weak self] in
            guard let self, let catalog = self.active else { return nil }
            return (catalog, self.deviceID)
        }
        manager.catalogImport = { [weak self] catalog, source in try self?.importCatalog(catalog, sourceDeviceID: source) }
        cloud.$user.map { $0?.id }.removeDuplicates().sink { [weak self] owner in
            guard let self, owner != self.ownerID else { return }
            self.openProfile(owner)
        }.store(in: &subscriptions)
        manager.$connectedVolumes.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, !self.readOnly else { return }
            self.applyActive()
        }.store(in: &subscriptions)
        cloud.$online.dropFirst().sink { [weak self] online in
            if online { Task { await self?.maintainCloud() } }
            self?.objectWillChange.send()
        }.store(in: &subscriptions)
        retry = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.maintainCloud() }
        }
    }

    deinit { retry?.invalidate(); scheduledSync?.cancel() }

    func openProfile(_ owner: String?, migrateLegacy: Bool = false) {
        cloud.stopListening()
        onlineBackups.reset()
        manager.catalogSession = UUID()
        ownerID = owner; readOnly = false; errorMessage = nil; lastSynchronizationError = nil
        manager.catalogBackupDirectory = files.url(for: owner).deletingPathExtension().appendingPathComponent("Backups")
        do {
            if let stored = try files.load(owner: owner) { archive = stored }
            else {
                archive = CatalogArchive()
                if owner == nil {
                    guard !manager.storageReadOnly else { throw CatalogArchiveError.unreadable }
                    let info = CatalogInfo(id: UUID(), name: "Il mio catalogo", createdAt: Date(),
                                           namingPattern: ProjectNaming.defaultPattern, colors: [:])
                    archive.catalogs = [StoredCatalog(info: info)]
                    archive.activeCatalogID = info.id
                    if migrateLegacy { capture() }
                }
                _ = persist()
            }
            if owner == nil {
                guestPreferences = archive.preferences ?? guestPreferences
                if archive.preferences == nil { archive.preferences = guestPreferences; _ = persist() }
            }
            manager.applyAppPreferences(preferences)
            applyActive()
            if let owner {
                cloud.startListening(owner: owner, preferencesMissing: { [weak self] in
                    guard let self, self.ownerID == owner else { return }
                    self.initializePreferencesIfMissing()
                }, receive: { [weak self] value in
                    guard let self, self.ownerID == owner, !self.readOnly else { return }
                    self.receiveRemote(value)
                })
                Task { await maintainCloud() }
            }
        } catch {
            archive = CatalogArchive(); readOnly = true; errorMessage = error.localizedDescription
            manager.applyCatalog(info: nil, projects: [], monitoredPaths: [], localIDs: [])
        }
    }

    func receiveRemote(_ value: CatalogRemoteValue) {
        guard ownerID != nil, !readOnly else { return }
        if value.revision <= (archive.revisions[value.object.key] ?? 0), archive.pending[value.object.key] == nil { return }
        do {
            try archive.receive(value)
            if persist() {
                if value.object == .preferences { manager.applyAppPreferences(preferences) }
                else { applyActive() }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    // Called only after Firestore confirms the document is absent on the server.
    func initializePreferencesIfMissing() {
        guard ownerID != nil, !readOnly, archive.revisions[CatalogObject.preferences.key] == nil,
              archive.pending[CatalogObject.preferences.key] == nil else { return }
        savePreferences(preferences)
    }

    func updatePreferences(_ preferences: SharedAppPreferences) {
        guard !readOnly, preferences != self.preferences else { return }
        savePreferences(preferences)
    }

    private func savePreferences(_ preferences: SharedAppPreferences) {
        do {
            archive.preferences = preferences
            if ownerID != nil { archive.enqueue(.preferences, payload: try CatalogArchive.encodeValue(preferences)) }
            guard persist() else { return }
            if ownerID == nil { guestPreferences = preferences }
            manager.applyAppPreferences(preferences)
            Task { await synchronize() }
        } catch { errorMessage = error.localizedDescription }
    }

    func createCatalog(name: String) {
        guard !readOnly else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { errorMessage = "Inserisci un nome di massimo 100 caratteri."; return }
        let info = CatalogInfo(id: UUID(), name: name, createdAt: Date(), namingPattern: ProjectNaming.defaultPattern, colors: [:])
        manager.catalogSession = UUID()
        archive.catalogs.append(StoredCatalog(info: info)); archive.activeCatalogID = info.id
        do {
            if ownerID != nil { archive.enqueue(CatalogObject(catalogID: info.id), payload: try CatalogArchive.encodeValue(info)) }
            if persist() { applyActive(); Task { await synchronize() } }
        } catch { errorMessage = error.localizedDescription }
    }

    func selectCatalog(_ id: UUID) {
        guard !readOnly, archive.catalogs.contains(where: { $0.id == id }) else { return }
        manager.catalogSession = UUID()
        archive.activeCatalogID = id
        if persist() { applyActive() }
    }

    var localCatalogsToImport: [StoredCatalog] {
        guard ownerID != nil, let local = try? files.load(owner: nil) else { return [] }
        return local.catalogs.filter { catalog in !archive.catalogs.contains { $0.id == catalog.id } }
    }

    @discardableResult
    func importLocalCatalogs() -> Int {
        guard ownerID != nil, !readOnly else { return 0 }
        let candidates = localCatalogsToImport
        guard !candidates.isEmpty else { return 0 }
        do {
            for catalog in candidates {
                try catalog.validate()
                archive.catalogs.append(catalog)
                archive.enqueue(CatalogObject(catalogID: catalog.id), payload: try CatalogArchive.encodeValue(catalog.info))
                for project in catalog.projects {
                    archive.enqueue(CatalogObject(catalogID: catalog.id, projectID: project.id), payload: try CatalogArchive.encodeValue(project))
                }
                if archive.activeCatalogID == nil { archive.activeCatalogID = catalog.id }
            }
            guard persist() else { return 0 }
            applyActive(); Task { await synchronize() }
            return candidates.count
        } catch { errorMessage = error.localizedDescription; return 0 }
    }

    func addImportedCatalog(_ source: StoredCatalog, name: String, sourceDeviceID: String?) throws {
        guard !readOnly else { throw CatalogArchiveError.unableToSave }
        try source.validate()
        let previous = archive
        var imported = source
        imported.info = CatalogInfo(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), createdAt: Date(),
                                    namingPattern: source.info.namingPattern, colors: source.info.colors)
        try imported.validate()
        if sourceDeviceID != deviceID { imported.device = DeviceCatalogState() }
        archive.catalogs.append(imported); archive.activeCatalogID = imported.id
        if ownerID != nil {
            archive.enqueue(CatalogObject(catalogID: imported.id), payload: try CatalogArchive.encodeValue(imported.info))
            for project in imported.projects {
                archive.enqueue(CatalogObject(catalogID: imported.id, projectID: project.id), payload: try CatalogArchive.encodeValue(project))
            }
        }
        guard persist() else { archive = previous; throw CatalogArchiveError.unableToSave }
        manager.catalogSession = UUID(); applyActive()
        Task { await synchronize() }
    }

    func importCatalog(_ source: StoredCatalog, sourceDeviceID: String?) throws {
        guard !readOnly, let index = archive.catalogs.firstIndex(where: { $0.id == archive.activeCatalogID }) else { throw CatalogArchiveError.unreadable }
        try source.validate()
        let previous = archive
        let old = archive.catalogs[index]
        var imported = source
        // A manual import replaces the current catalog contents, preserving its cloud identity.
        imported.info = CatalogInfo(id: old.id, name: source.info.name, createdAt: old.info.createdAt,
                                    namingPattern: source.info.namingPattern, colors: source.info.colors)
        if sourceDeviceID != deviceID { imported.device = DeviceCatalogState() }
        if ownerID != nil {
            archive.enqueue(CatalogObject(catalogID: old.id), payload: try CatalogArchive.encodeValue(imported.info))
            for project in imported.projects {
                archive.enqueue(CatalogObject(catalogID: old.id, projectID: project.id), payload: try CatalogArchive.encodeValue(project))
            }
            for project in old.projects where !imported.projects.contains(where: { $0.id == project.id }) {
                archive.enqueue(CatalogObject(catalogID: old.id, projectID: project.id), payload: nil)
            }
        }
        archive.catalogs[index] = imported
        manager.catalogSession = UUID()
        guard persist() else { archive = previous; throw CatalogArchiveError.unableToSave }
        applyActive(); Task { await synchronize() }
    }

    private func persist() -> Bool {
        do { try files.save(archive, owner: ownerID); return true }
        catch { readOnly = true; errorMessage = error.localizedDescription; return false }
    }

    private func record(_ project: VideoProject, previous: CatalogProject?) -> CatalogProject {
        var location = previous
        if previous == nil || (previous?.sourceDeviceID == deviceID && manager.localProjectIDs?.contains(project.id) != false && !project.path.hasPrefix("/__folderflow_remote__/")) {
            let url = URL(fileURLWithPath: project.path)
            let resources = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey])
            let volumeRoot = resources?.volume ?? (project.path.hasPrefix("/Volumes/") ? URL(fileURLWithPath: "/Volumes/" + project.volumeIdentifier) : URL(fileURLWithPath: "/"))
            let prefix = volumeRoot.path == "/" ? "/" : volumeRoot.path + "/"
            location = CatalogProject(id: project.id, name: project.name, date: project.date, volumeName: project.volumeIdentifier,
                                      volumeUUID: resources?.volumeUUIDString ?? previous?.volumeUUID, sourceDeviceID: deviceID, sourcePath: project.path,
                                      relativePath: project.path.hasPrefix(prefix) ? String(project.path.dropFirst(prefix.count)) : nil,
                                      folderSize: project.folderSize, folderContents: project.folderContents, isAnalyzed: project.isAnalyzed,
                                      billingStatus: project.billingStatus, deadline: project.deadline, isCompleted: project.isCompleted, comments: project.comments)
        }
        var result = location!
        result.name = project.name; result.date = project.date; result.folderSize = project.folderSize
        result.folderContents = project.folderContents; result.isAnalyzed = project.isAnalyzed
        result.billingStatus = project.billingStatus; result.deadline = project.deadline
        result.isCompleted = project.isCompleted; result.comments = project.comments
        return result
    }

    private func capture() {
        guard !applying, !readOnly, let index = archive.catalogs.firstIndex(where: { $0.id == archive.activeCatalogID }) else { return }
        do {
            let old = archive.catalogs[index]
            var updated = old
            updated.info.namingPattern = manager.projectNamingPattern
            updated.info.colors = manager.volumeColors.mapValues { ColorRGB.fromColor($0) }
            updated.device.monitoredPaths = manager.monitoredPaths
            updated.projects = manager.projects.map { project in
                if manager.localProjectIDs?.contains(project.id) == true || !old.projects.contains(where: { $0.id == project.id }) {
                    updated.device.projectPaths[project.id.uuidString] = project.path
                }
                return record(project, previous: old.projects.first { $0.id == project.id })
            }
            if ownerID != nil {
                if try CatalogArchive.encodeValue(old.info) != CatalogArchive.encodeValue(updated.info) {
                    archive.enqueue(CatalogObject(catalogID: old.id), payload: try CatalogArchive.encodeValue(updated.info))
                }
                for project in updated.projects {
                    let data = try CatalogArchive.encodeValue(project)
                    let previous = try old.projects.first(where: { $0.id == project.id }).map(CatalogArchive.encodeValue)
                    if data != previous { archive.enqueue(CatalogObject(catalogID: old.id, projectID: project.id), payload: data) }
                }
                for removed in old.projects where !updated.projects.contains(where: { $0.id == removed.id }) {
                    archive.enqueue(CatalogObject(catalogID: old.id, projectID: removed.id), payload: nil)
                    updated.device.projectPaths.removeValue(forKey: removed.id.uuidString)
                }
            }
            archive.catalogs[index] = updated
            if persist() {
                scheduledSync?.cancel()
                scheduledSync = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 600_000_000) } catch { return }
                    await self?.synchronize()
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func localPath(_ project: CatalogProject, device: DeviceCatalogState) -> String? {
        if let uuid = project.volumeUUID, let relative = project.relativePath {
            guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return nil }
            for volume in manager.connectedVolumes {
                let actual = try? volume.url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
                if actual == uuid { return volume.url.appendingPathComponent(relative).path }
            }
            // A remembered path is usable only if it still points to the same disk.
            if let path = device.projectPaths[project.id.uuidString] ?? (project.sourceDeviceID == deviceID ? project.sourcePath : nil) {
                let actual = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
                if actual == uuid { return path }
                if !FileManager.default.fileExists(atPath: path) { return path }
            }
            return nil
        }
        if let path = device.projectPaths[project.id.uuidString] { return path }
        return project.sourceDeviceID == deviceID ? project.sourcePath : nil
    }

    private func applyActive() {
        applying = true
        defer { applying = false }
        guard let catalog = active else { manager.applyCatalog(info: nil, projects: [], monitoredPaths: [], localIDs: []); return }
        var localIDs = Set<UUID>()
        let projects = catalog.projects.map { record -> VideoProject in
            let path = localPath(record, device: catalog.device)
            if path != nil { localIDs.insert(record.id) }
            let exists = path.map { FileManager.default.fileExists(atPath: $0) } ?? false
            return VideoProject(id: record.id, name: record.name, path: path ?? "/__folderflow_remote__/" + record.id.uuidString,
                                date: record.date, isOnline: exists, volumeIdentifier: record.volumeName,
                                folderSize: record.folderSize, folderContents: record.folderContents, isAnalyzed: record.isAnalyzed,
                                billingStatus: record.billingStatus, isMissing: false, deadline: record.deadline,
                                isCompleted: record.isCompleted, comments: record.comments)
        }
        manager.catalogBackupDirectory = files.url(for: ownerID).deletingPathExtension().appendingPathComponent(catalog.id.uuidString + "/Backups")
        manager.applyCatalog(info: catalog.info, projects: projects, monitoredPaths: catalog.device.monitoredPaths, localIDs: localIDs)
    }

    private func maintainCloud() async {
        guard !syncing, !readOnly, let owner = ownerID else { return }
        await synchronize()
        guard ownerID == owner else { return }
        await onlineBackups.runIfNeeded(owner: owner, deviceID: deviceID)
    }

    func synchronize(using transport: CatalogTransport? = nil) async {
        guard !syncing, !readOnly, let owner = ownerID, cloud.online, (transport != nil || cloud.configured) else { return }
        syncing = true
        defer { syncing = false }
        let service: CatalogTransport = transport ?? cloud
        while ownerID == owner, !readOnly,
              let mutation = archive.pending.values.filter({ archive.conflicts[$0.object.key] == nil }).sorted(by: {
                  if ($0.object.projectID == nil) != ($1.object.projectID == nil) { return $0.object.projectID == nil }
                  return $0.object.key < $1.object.key
              }).first {
            do {
                let result = try await service.commit(owner: owner, mutation: mutation)
                guard ownerID == owner else { return }
                switch result {
                case .accepted(let value): try archive.acknowledge(value, mutationID: mutation.id)
                case .conflict(let value): archive.conflicts[value.object.key] = CatalogConflict(remote: value)
                }
                guard persist() else { return }
                if errorMessage == lastSynchronizationError { errorMessage = nil }
                lastSynchronizationError = nil
            } catch {
                if ownerID == owner {
                    lastSynchronizationError = error.localizedDescription
                    errorMessage = lastSynchronizationError
                }
                return
            }
        }
    }

    func resolveConflict(_ key: String, keepLocal: Bool) {
        do {
            try archive.resolve(key, keepLocal: keepLocal)
            if persist() {
                manager.applyAppPreferences(preferences)
                applyActive()
                Task { await synchronize() }
            }
        } catch { errorMessage = error.localizedDescription }
    }
}
