import XCTest
@testable import FolderFlow

@MainActor
private final class MemoryCatalogServer: CatalogTransport {
    var values: [String: CatalogRemoteValue] = [:]
    var nextError: Error?
    func commit(owner: String, mutation: CatalogMutation) async throws -> CatalogCommitResult {
        if let error = nextError { nextError = nil; throw error }
        let key = owner + "/" + mutation.object.key
        let old = values[key]
        if let old, old.mutationID == mutation.id { return .accepted(old) }
        if (old?.revision ?? 0) != mutation.baseRevision { return .conflict(old!) }
        let value = CatalogRemoteValue(object: mutation.object, revision: (old?.revision ?? 0) + 1, mutationID: mutation.id, payload: mutation.payload)
        values[key] = value
        return .accepted(value)
    }
    func deliver(to workspace: CatalogWorkspace, owner: String) {
        values.filter { $0.key.hasPrefix(owner + "/") }.values.sorted {
            ($0.object.projectID == nil ? 0 : 1) < ($1.object.projectID == nil ? 0 : 1)
        }.forEach { workspace.receiveRemote($0) }
    }
}

@MainActor
private final class WorkspaceFixture {
    let domain = "FolderFlowWorkspaceTests." + UUID().uuidString
    let root: URL
    let defaults: UserDefaults
    let manager: DataManager
    let cloud: CloudService
    let workspace: CatalogWorkspace
    init(device: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderFlowWorkspace-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: domain)!
        manager = DataManager(defaults: defaults, backupDirectory: root.appendingPathComponent("backups"))
        cloud = CloudService(configure: false)
        workspace = CatalogWorkspace(manager: manager, cloud: cloud, root: root.appendingPathComponent("catalogs"), deviceID: device)
    }
    func addProject(name: String = "26_10_01_Fixture", comments: String = "Note originali") throws -> VideoProject {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let project = VideoProject(name: name, path: directory.path, date: Date(), volumeIdentifier: "Fixture HD", folderSize: 1,
                                   billingStatus: .billed, isCompleted: true, comments: comments)
        manager.addProject(project)
        return project
    }
}

final class CatalogWorkspaceTests: XCTestCase {
    @MainActor
    func testImportedCatalogQueuesCloudAndRestoresAfterAccountSwitch() async throws {
        let a = try WorkspaceFixture(device: "A"), b = try WorkspaceFixture(device: "B")
        defer { a.defaults.removePersistentDomain(forName: a.domain); b.defaults.removePersistentDomain(forName: b.domain) }
        let project = try a.addProject()
        let transfer = try CatalogTransfer.decode(a.manager.catalogExportData(), name: "Importato", deviceID: "A")
        a.workspace.openProfile("alice")
        try a.workspace.addImportedCatalog(transfer.catalog, name: "Archivio importato", sourceDeviceID: "A")
        XCTAssertEqual(a.workspace.archive.pending.count, 2)
        a.workspace.openProfile("bob"); a.workspace.openProfile("alice")
        XCTAssertEqual(a.manager.projects.first?.id, project.id)
        XCTAssertTrue(a.manager.projects[0].isCompleted)
        let server = MemoryCatalogServer()
        await a.workspace.synchronize(using: server)
        b.manager.connectedVolumes = []
        b.workspace.openProfile("alice"); server.deliver(to: b.workspace, owner: "alice")
        XCTAssertEqual(b.manager.projects.first?.id, project.id)
        XCTAssertTrue(b.manager.projects[0].isCompleted)
        XCTAssertEqual(b.manager.projects[0].billingStatus, .billed)
        XCTAssertFalse(b.manager.projects[0].isOnline)
        XCTAssertTrue(b.manager.monitoredPaths.isEmpty)
    }

    @MainActor
    func testImportedCopyKeepsExistingCatalogAndModernSourceMetadata() throws {
        let a = try WorkspaceFixture(device: "A"), b = try WorkspaceFixture(device: "B")
        defer { a.defaults.removePersistentDomain(forName: a.domain); b.defaults.removePersistentDomain(forName: b.domain) }
        let original = try a.addProject()
        a.manager.updateProjectNamingPattern("{AAAA}_{NN}_{Nome}")
        a.manager.addMonitoredPath(a.root.path)
        let existing = try b.addProject(name: "26_10_02_Existing")
        let previousID = try XCTUnwrap(b.workspace.archive.activeCatalogID)
        let transfer = try CatalogTransfer.decode(a.manager.catalogExportData(), name: "Transfer", deviceID: "B")
        b.manager.connectedVolumes = []
        try b.workspace.addImportedCatalog(transfer.catalog, name: "Importato", sourceDeviceID: transfer.sourceDeviceID)
        XCTAssertEqual(b.workspace.archive.catalogs.count, 2)
        XCTAssertEqual(b.manager.projects.first?.id, original.id)
        XCTAssertEqual(b.manager.projectNamingPattern, "{AAAA}_{NN}_{Nome}")
        XCTAssertTrue(b.manager.monitoredPaths.isEmpty)
        XCTAssertFalse(b.manager.projects[0].isOnline)
        XCTAssertEqual(b.workspace.active?.projects[0].sourceDeviceID, "A")
        b.workspace.selectCatalog(previousID)
        XCTAssertEqual(b.manager.projects.first?.id, existing.id)
    }

    @MainActor
    func testLegacyImportAndRestoreUseTheSameValidatedCatalogPath() async throws {
        let fixture = try WorkspaceFixture(device: "A")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
        let original = try fixture.addProject()
        let recovery = try await fixture.manager.createRecoveryBackup()
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
        let changed = VideoProject(name: original.name, path: original.path, date: original.date, volumeIdentifier: "HD", folderSize: 1,
                                   billingStatus: .toBill, isCompleted: false, comments: "Dal vecchio JSON")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let file = fixture.root.appendingPathComponent("legacy.json")
        try encoder.encode(AppData(projects: [changed], volumeColors: [:])).write(to: file)
        XCTAssertTrue(fixture.manager.importFromFile(at: file.path))
        XCTAssertFalse(fixture.manager.projects[0].isCompleted)
        XCTAssertEqual(fixture.manager.projects[0].billingStatus, .toBill)
        XCTAssertTrue(fixture.manager.restoreFromBackup(at: recovery))
        XCTAssertEqual(fixture.manager.projects[0].id, original.id)
        XCTAssertTrue(fixture.manager.projects[0].isCompleted)
        XCTAssertEqual(fixture.manager.projects[0].billingStatus, .billed)
    }

    @MainActor
    func testBackupsCompleteForEmptyCatalogsAndNeverOverwriteThePreviousCopy() async throws {
        let fixture = try WorkspaceFixture(device: "A")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
        let first = try await fixture.manager.createRecoveryBackup()
        let second = try await fixture.manager.createRecoveryBackup()
        XCTAssertNotEqual(first, second)
        for url in [first, second] {
            let transfer = try CatalogTransfer.read(url, deviceID: "A")
            XCTAssertTrue(transfer.catalog.projects.isEmpty)
            XCTAssertEqual(transfer.catalog.info.id, fixture.workspace.archive.activeCatalogID)
        }
        XCTAssertEqual(fixture.manager.getAvailableBackups().count, 2)
    }

    @MainActor
    func testAlreadyImportedLocalCatalogsAreReportedAndNotDuplicated() throws {
        let fixture = try WorkspaceFixture(device: "A")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
        _ = try fixture.addProject()
        fixture.workspace.openProfile("alice")
        XCTAssertEqual(fixture.workspace.localCatalogsToImport.count, 1)
        XCTAssertEqual(fixture.workspace.importLocalCatalogs(), 1)
        XCTAssertTrue(fixture.workspace.localCatalogsToImport.isEmpty)
        XCTAssertEqual(fixture.workspace.importLocalCatalogs(), 0)
        XCTAssertEqual(fixture.workspace.archive.catalogs.count, 1)
    }

    @MainActor
    func testFailedImportSaveDoesNotReportSuccessOrReplaceTheCurrentCatalog() throws {
        let fixture = try WorkspaceFixture(device: "A")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
        _ = try fixture.addProject()
        let source = try XCTUnwrap(fixture.workspace.active)
        let id = fixture.workspace.archive.activeCatalogID
        let directory = fixture.root.appendingPathComponent("catalogs")
        try FileManager.default.removeItem(at: directory)
        try Data("Not a directory".utf8).write(to: directory)
        XCTAssertThrowsError(try fixture.workspace.addImportedCatalog(source, name: "Cannot save", sourceDeviceID: "A"))
        XCTAssertTrue(fixture.workspace.readOnly)
        XCTAssertEqual(fixture.workspace.archive.catalogs.count, 1)
        XCTAssertEqual(fixture.workspace.archive.activeCatalogID, id)
    }

    @MainActor
    func testPreferenceRetryClearsRecoveredSyncErrorAndKeepsPendingEdit() async throws {
        let fixture = try WorkspaceFixture(device: "A")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
        let server = MemoryCatalogServer()
        fixture.workspace.openProfile("alice")
        fixture.workspace.updatePreferences(SharedAppPreferences(launchAtLogin: true, hideDockIcon: false))
        server.nextError = NSError(domain: "Transient network fixture", code: 1)
        await fixture.workspace.synchronize(using: server)
        XCTAssertNotNil(fixture.workspace.errorMessage)
        XCTAssertNotNil(fixture.workspace.archive.pending[CatalogObject.preferences.key])
        await fixture.workspace.synchronize(using: server)
        XCTAssertNil(fixture.workspace.errorMessage, "A recovered connection must not leave the status dot red")
        XCTAssertTrue(fixture.workspace.archive.pending.isEmpty)
        XCTAssertTrue(fixture.workspace.preferences.launchAtLogin)
    }

    @MainActor
    func testSharedPreferencesSyncAndRestoreOfflineWithoutCopyingDiskPaths() async throws {
        let a = try WorkspaceFixture(device: "A"), b = try WorkspaceFixture(device: "B")
        defer { a.defaults.removePersistentDomain(forName: a.domain); b.defaults.removePersistentDomain(forName: b.domain) }
        let server = MemoryCatalogServer()
        a.manager.addMonitoredPath(a.root.path)
        a.workspace.openProfile("alice"); a.workspace.importLocalCatalogs()
        let preferences = SharedAppPreferences(launchAtLogin: true, hideDockIcon: true)
        a.workspace.updatePreferences(preferences)
        XCTAssertEqual(a.manager.appPreferences, preferences)
        XCTAssertNotNil(a.workspace.archive.pending[CatalogObject.preferences.key])
        await a.workspace.synchronize(using: server)
        b.workspace.openProfile("alice"); server.deliver(to: b.workspace, owner: "alice")
        XCTAssertEqual(b.workspace.preferences, preferences)
        XCTAssertEqual(b.manager.appPreferences, preferences)
        XCTAssertTrue(b.manager.monitoredPaths.isEmpty)
        XCTAssertTrue(b.workspace.archive.pending.isEmpty)
        b.workspace.openProfile(nil)
        b.workspace.openProfile("alice")
        XCTAssertEqual(b.workspace.preferences, preferences, "The cached account preferences must work without Firebase or Internet")
        XCTAssertEqual(b.manager.appPreferences, preferences)
    }

    @MainActor
    func testFreshComputerDoesNotSeedDefaultsBeforeServerConfirmsAbsence() async throws {
        let a = try WorkspaceFixture(device: "A"), b = try WorkspaceFixture(device: "B")
        defer { a.defaults.removePersistentDomain(forName: a.domain); b.defaults.removePersistentDomain(forName: b.domain) }
        let server = MemoryCatalogServer()
        a.workspace.openProfile("alice")
        XCTAssertNil(a.workspace.archive.preferences)
        XCTAssertTrue(a.workspace.archive.pending.isEmpty)
        a.workspace.initializePreferencesIfMissing()
        let mutation = try XCTUnwrap(a.workspace.archive.pending[CatalogObject.preferences.key])
        a.workspace.initializePreferencesIfMissing()
        XCTAssertEqual(a.workspace.archive.pending[CatalogObject.preferences.key]?.id, mutation.id)
        a.workspace.updatePreferences(SharedAppPreferences(launchAtLogin: true, hideDockIcon: false))
        await a.workspace.synchronize(using: server)
        b.workspace.openProfile("alice")
        XCTAssertNil(b.workspace.archive.preferences)
        XCTAssertTrue(b.workspace.archive.pending.isEmpty)
        server.deliver(to: b.workspace, owner: "alice")
        b.workspace.initializePreferencesIfMissing()
        XCTAssertTrue(b.workspace.preferences.launchAtLogin)
        XCTAssertTrue(b.workspace.archive.pending.isEmpty, "A new Mac must not overwrite the account with its defaults")
    }

    @MainActor
    func testGuestAndDifferentAccountsKeepTheirOwnPreferences() throws {
        let fixture = try WorkspaceFixture(device: "A")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
        let guest = SharedAppPreferences(launchAtLogin: true, hideDockIcon: false)
        let alice = SharedAppPreferences(launchAtLogin: false, hideDockIcon: false)
        let bob = SharedAppPreferences(launchAtLogin: false, hideDockIcon: true)
        fixture.workspace.updatePreferences(guest)
        fixture.workspace.openProfile("alice"); fixture.workspace.updatePreferences(alice)
        fixture.workspace.openProfile("bob")
        XCTAssertEqual(fixture.workspace.preferences, guest, "A new account uses this Mac's guest baseline, never another account's preferences")
        fixture.workspace.updatePreferences(bob)
        fixture.workspace.openProfile("alice")
        XCTAssertEqual(fixture.workspace.preferences, alice)
        XCTAssertEqual(fixture.manager.appPreferences, alice)
        fixture.workspace.openProfile("bob")
        XCTAssertEqual(fixture.workspace.preferences, bob)
        fixture.workspace.openProfile(nil)
        XCTAssertEqual(fixture.workspace.preferences, guest)
        XCTAssertEqual(fixture.manager.appPreferences, guest)
    }

    @MainActor
    func testConcurrentPreferenceEditsPreserveLocalVersionUntilConflictIsResolved() async throws {
        let a = try WorkspaceFixture(device: "A"), b = try WorkspaceFixture(device: "B")
        defer { a.defaults.removePersistentDomain(forName: a.domain); b.defaults.removePersistentDomain(forName: b.domain) }
        let server = MemoryCatalogServer()
        a.workspace.openProfile("alice"); a.workspace.initializePreferencesIfMissing()
        await a.workspace.synchronize(using: server)
        b.workspace.openProfile("alice"); server.deliver(to: b.workspace, owner: "alice")
        let local = SharedAppPreferences(launchAtLogin: true, hideDockIcon: false)
        let remote = SharedAppPreferences(launchAtLogin: false, hideDockIcon: true)
        a.workspace.updatePreferences(local); b.workspace.updatePreferences(remote)
        await b.workspace.synchronize(using: server)
        server.deliver(to: a.workspace, owner: "alice")
        XCTAssertEqual(a.workspace.preferences, local)
        await a.workspace.synchronize(using: server)
        XCTAssertNotNil(a.workspace.archive.conflicts[CatalogObject.preferences.key])
        XCTAssertEqual(a.manager.appPreferences, local)
        a.workspace.resolveConflict(CatalogObject.preferences.key, keepLocal: false)
        XCTAssertEqual(a.workspace.preferences, remote)
        XCTAssertEqual(a.manager.appPreferences, remote)
        XCTAssertTrue(a.workspace.archive.pending.isEmpty)
    }

    @MainActor
    func testCatalogsAndAccountsHaveSeparateLocalData() throws {
        let fixture = try WorkspaceFixture(device: "A")
        let guest = fixture.workspace.archive.activeCatalogID!
        let project = try fixture.addProject()
        fixture.manager.addMonitoredPath(fixture.root.path)
        fixture.manager.updateProjectNamingPattern("{AAAA}_{NN}_{Nome}")
        fixture.workspace.createCatalog(name: "Secondo catalogo")
        XCTAssertTrue(fixture.manager.projects.isEmpty)
        XCTAssertTrue(fixture.manager.monitoredPaths.isEmpty)
        XCTAssertEqual(fixture.manager.projectNamingPattern, ProjectNaming.defaultPattern)
        fixture.workspace.selectCatalog(guest)
        XCTAssertEqual(fixture.manager.projects.first?.id, project.id)
        XCTAssertEqual(fixture.manager.monitoredPaths, [fixture.root.path])
        XCTAssertEqual(fixture.manager.projectNamingPattern, "{AAAA}_{NN}_{Nome}")
        fixture.workspace.openProfile("alice")
        XCTAssertTrue(fixture.manager.projects.isEmpty)
        fixture.workspace.importLocalCatalogs()
        XCTAssertEqual(fixture.manager.projects.first?.comments, "Note originali")
        fixture.workspace.openProfile("bob")
        XCTAssertTrue(fixture.manager.projects.isEmpty)
        XCTAssertTrue(fixture.workspace.archive.pending.isEmpty)
        fixture.workspace.openProfile("alice")
        XCTAssertEqual(fixture.manager.projects.first?.id, project.id)
        fixture.workspace.openProfile(nil)
        XCTAssertEqual(fixture.manager.projects.first?.id, project.id)
        fixture.defaults.removePersistentDomain(forName: fixture.domain)
    }

    @MainActor
    func testTwoComputersKeepRemoteProjectsOfflineAndPreserveBothConflictVersions() async throws {
        let a = try WorkspaceFixture(device: "A"), b = try WorkspaceFixture(device: "B")
        let project = try a.addProject()
        let server = MemoryCatalogServer()
        a.workspace.openProfile("alice"); a.workspace.importLocalCatalogs()
        await a.workspace.synchronize(using: server)
        XCTAssertTrue(a.workspace.archive.pending.isEmpty)
        b.manager.connectedVolumes = []
        b.workspace.openProfile("alice"); server.deliver(to: b.workspace, owner: "alice")
        XCTAssertEqual(b.manager.projects.first?.id, project.id)
        XCTAssertFalse(b.manager.projects[0].isOnline)
        XCTAssertFalse(b.manager.projects[0].isMissing)
        XCTAssertTrue(b.manager.projects[0].path.hasPrefix("/__folderflow_remote__/"))
        XCTAssertTrue(b.manager.monitoredPaths.isEmpty)
        b.manager.updateOnlineStatus()
        XCTAssertFalse(b.manager.projects[0].isMissing)
        a.manager.updateProjectInfo(for: project.id, deadline: nil, isCompleted: true, comments: "Modifica A offline")
        b.manager.updateProjectInfo(for: project.id, deadline: nil, isCompleted: false, comments: "Modifica B offline")
        await b.workspace.synchronize(using: server)
        await a.workspace.synchronize(using: server)
        XCTAssertEqual(a.workspace.archive.conflicts.count, 1)
        XCTAssertEqual(a.manager.projects[0].comments, "Modifica A offline")
        let conflict = try XCTUnwrap(a.workspace.archive.conflicts.values.first)
        let remote = try CatalogArchive.decodeValue(CatalogProject.self, XCTUnwrap(conflict.remote.payload))
        XCTAssertEqual(remote.comments, "Modifica B offline")
        XCTAssertEqual(remote.sourceDeviceID, "A", "Editing metadata remotely must not move the source location")
        a.workspace.resolveConflict(conflict.id, keepLocal: true)
        await a.workspace.synchronize(using: server)
        XCTAssertTrue(a.workspace.archive.conflicts.isEmpty)
        server.deliver(to: b.workspace, owner: "alice")
        XCTAssertEqual(b.manager.projects.first?.comments, "Modifica A offline")
        XCTAssertEqual(b.manager.projects.first?.id, project.id)
        a.defaults.removePersistentDomain(forName: a.domain); b.defaults.removePersistentDomain(forName: b.domain)
    }

    @MainActor
    func testTombstonesCannotSilentlyResurrectDeletedProjects() async throws {
        let a = try WorkspaceFixture(device: "A"), b = try WorkspaceFixture(device: "B")
        let project = try a.addProject()
        let server = MemoryCatalogServer()
        a.workspace.openProfile("alice"); a.workspace.importLocalCatalogs()
        await a.workspace.synchronize(using: server)
        b.manager.connectedVolumes = []
        b.workspace.openProfile("alice"); server.deliver(to: b.workspace, owner: "alice")
        a.manager.updateProjectInfo(for: project.id, deadline: nil, isCompleted: false, comments: "Modifica senza rete")
        b.manager.deleteProject(b.manager.projects[0])
        await b.workspace.synchronize(using: server)
        await a.workspace.synchronize(using: server)
        let conflict = try XCTUnwrap(a.workspace.archive.conflicts.values.first)
        XCTAssertNil(conflict.remote.payload)
        a.workspace.resolveConflict(conflict.id, keepLocal: false)
        XCTAssertTrue(a.manager.projects.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path), "Catalog deletion must not delete media")
        a.defaults.removePersistentDomain(forName: a.domain); b.defaults.removePersistentDomain(forName: b.domain)
    }

    @MainActor
    func testManualBackupPreservesRemoteLocationsNamingAndLocalDeviceIsolation() throws {
        let a = try WorkspaceFixture(device: "A"), b = try WorkspaceFixture(device: "B")
        defer { a.defaults.removePersistentDomain(forName: a.domain); b.defaults.removePersistentDomain(forName: b.domain) }
        let project = try a.addProject()
        a.manager.updateProjectNamingPattern("{AAAA}_{NN}_{Nome}")
        a.manager.addMonitoredPath(a.root.path)
        let exported = a.root.appendingPathComponent("export.json")
        XCTAssertTrue(a.manager.exportToFile(at: exported.path))
        b.manager.connectedVolumes = []
        XCTAssertTrue(b.manager.importFromFile(at: exported.path))
        XCTAssertEqual(b.manager.projects.first?.id, project.id)
        XCTAssertEqual(b.manager.projectNamingPattern, "{AAAA}_{NN}_{Nome}")
        XCTAssertTrue(b.manager.monitoredPaths.isEmpty)
        XCTAssertFalse(b.manager.projects[0].isOnline)
        XCTAssertEqual(b.workspace.active?.projects[0].sourceDeviceID, "A")
        XCTAssertEqual(b.workspace.active?.projects[0].sourcePath, project.path)
        XCTAssertNotEqual(a.manager.getBackupDirectory(), b.manager.getBackupDirectory())
    }

    @MainActor
    func testAnUnrelatedDiskAtTheSamePathCannotBecomeTheProjectSource() throws {
        let fixture = try WorkspaceFixture(device: "A")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
        _ = try fixture.addProject()
        var catalog = try XCTUnwrap(fixture.workspace.active)
        catalog.projects[0].volumeUUID = "different-disk-uuid"
        try fixture.workspace.importCatalog(catalog, sourceDeviceID: "A")
        XCTAssertFalse(fixture.manager.projects[0].isOnline)
        XCTAssertTrue(fixture.manager.projects[0].path.hasPrefix("/__folderflow_remote__/"))
        let sourcePath = catalog.projects[0].sourcePath
        fixture.manager.updateProjectInfo(for: catalog.projects[0].id, deadline: nil, isCompleted: false, comments: "Offline note")
        XCTAssertEqual(fixture.workspace.active?.projects[0].sourcePath, sourcePath)
        XCTAssertEqual(fixture.workspace.active?.projects[0].volumeUUID, "different-disk-uuid")
    }

    @MainActor
    func testScanCannotWriteResultsIntoAnotherCatalog() async throws {
        let fixture = try WorkspaceFixture(device: "A")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
        let root = fixture.root.appendingPathComponent("scan")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("26_10_01_A"), withIntermediateDirectories: true)
        let scanner = FolderScanner(dataManager: fixture.manager)
        let scan = Task { await scanner.scanFolders([root]) }
        await Task.yield()
        fixture.workspace.createCatalog(name: "Altro catalogo")
        await scan.value
        XCTAssertTrue(fixture.manager.projects.isEmpty)
        XCTAssertEqual(fixture.workspace.active?.info.name, "Altro catalogo")
    }

    @MainActor
    func testPartialScanPreservesOtherRootsAndSameNamesKeepDistinctIDs() throws {
        let fixture = try WorkspaceFixture(device: "A")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
        let a = try fixture.addProject()
        let path = fixture.root.appendingPathComponent("second-root/" + a.name)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let b = VideoProject(name: a.name, path: path.path, date: Date(), volumeIdentifier: "Other HD", comments: "Other project")
        fixture.manager.addProject(b)
        fixture.manager.syncProjects(foundProjects: [a], scannedVolumes: [], scannedRoots: [URL(fileURLWithPath:a.path)])
        XCTAssertEqual(Set(fixture.manager.projects.map(\.id)), [a.id, b.id])
        XCTAssertEqual(fixture.manager.projects.first { $0.id == b.id }?.comments, "Other project")
        XCTAssertFalse(fixture.manager.projects.first { $0.id == b.id }!.isMissing)
    }

    @MainActor
    func testLegacyStartupReadsExternalCatalogBeforeAnyWriteAndPreservesCorruptData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = "FolderFlowStartupTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let project = VideoProject(name: "26_10_01_OnlyExternal", path: root.path, date: Date(), volumeIdentifier: "HD", folderSize: 1)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(AppData(projects: [project], volumeColors: [:]))
        let external = root.appendingPathComponent("external.json")
        try json.write(to: external)
        defaults.set(external.path, forKey: "ExternalDataPath")
        let manager = DataManager(defaults: defaults, backupDirectory: root.appendingPathComponent("backups"))
        XCTAssertEqual(manager.projects.first?.id, project.id)
        try await Task.sleep(nanoseconds: 50_000_000)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(AppData.self, from: Data(contentsOf: external)).projects.first?.id, project.id)
        manager.setExternalDataPath(nil)
        defaults.removeObject(forKey: "ExternalDataPath")
        let corrupted = Data("corrupt-json".utf8)
        defaults.set(corrupted, forKey: "SavedProjects")
        let unreadable = DataManager(defaults: defaults, backupDirectory: root.appendingPathComponent("no-backups"))
        XCTAssertTrue(unreadable.storageReadOnly)
        XCTAssertEqual(defaults.data(forKey: "SavedProjects"), corrupted)
    }

    @MainActor
    func testCancelledScanDoesNotCommitPartialResults() async throws {
        let fixture = try WorkspaceFixture(device: "A")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.domain) }
        let project = try fixture.addProject()
        let scanner = FolderScanner(dataManager: fixture.manager)
        let task = Task { await scanner.scanFolders([fixture.root], isSync: true) }
        for _ in 0..<30 { if scanner.isScanning { break }; await Task.yield() }
        scanner.cancelScan()
        await task.value
        XCTAssertEqual(fixture.manager.projects.map(\.id), [project.id])
        XCTAssertFalse(fixture.manager.projects[0].isMissing)
        XCTAssertFalse(scanner.isScanning)
    }

    func testAtomicArchiveRecoversPreviousFileAndRefusesToReplaceUnreadableData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = CatalogArchiveFile(root: root)
        var archive = CatalogArchive()
        let info = CatalogInfo(id: UUID(), name: "Versione buona", createdAt: Date(), namingPattern: ProjectNaming.defaultPattern, colors: [:])
        archive.catalogs = [StoredCatalog(info: info)]; archive.activeCatalogID = info.id
        try files.save(archive, owner: "alice")
        archive.catalogs[0].info.name = "Versione successiva"
        try files.save(archive, owner: "alice")
        let file = files.url(for: "alice")
        try Data("corrupted".utf8).write(to: file)
        XCTAssertEqual(try files.load(owner: "alice")?.catalogs.first?.info.name, "Versione buona")
        try Data("also-corrupted".utf8).write(to: file.appendingPathExtension("previous"))
        XCTAssertThrowsError(try files.load(owner: "alice"))
        XCTAssertEqual(try Data(contentsOf: file), Data("corrupted".utf8))
        XCTAssertNil(try files.load(owner: "bob"))
        XCTAssertNotEqual(files.url(for: "alice"), files.url(for: "bob"))
    }
}
