import XCTest
@testable import FolderFlow

final class NamingIntegrationTests: XCTestCase {
    @MainActor
    func testPreferencePersistsWithoutChangingExistingCatalog() throws {
        let domain = "FolderFlowTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let manager = DataManager(defaults: defaults, backupDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(domain + "-backups"))
        XCTAssertEqual(manager.projectNamingPattern, ProjectNaming.defaultPattern)
        let project = VideoProject(name: "26_10_01_Lavoro", path: "/tmp/catalog-only-fixture", date: Date(), isOnline: false, volumeIdentifier: "FixtureDisk",
                                   folderSize: 1, billingStatus: .billed, isCompleted: true, comments: "Preserva note")
        manager.addProject(project)
        let savedBefore = defaults.data(forKey: "SavedProjects")
        manager.updateProjectNamingPattern("{Nome} - {AAAA}{MM}{GG} - {NN}")
        XCTAssertEqual(defaults.string(forKey: ProjectNaming.preferenceKey), "{Nome} - {AAAA}{MM}{GG} - {NN}")
        XCTAssertEqual(defaults.data(forKey: "SavedProjects"), savedBefore)
        let restored = DataManager(defaults: defaults, backupDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(domain + "-backups"))
        XCTAssertEqual(restored.projectNamingPattern, manager.projectNamingPattern)
        XCTAssertEqual(restored.projects.first?.id, project.id)
        XCTAssertEqual(restored.projects.first?.comments, "Preserva note")
        manager.updateProjectNamingPattern("{Nome}")
        XCTAssertEqual(manager.projectNamingPattern, "{Nome} - {AAAA}{MM}{GG} - {NN}")
        XCTAssertEqual(manager.projectYear(project), "2026")
    }

    @MainActor
    func testScannerFindsNewFormatAndRefreshesKnownLegacyProject() async throws {
        let domain = "FolderFlowTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderFlowNaming-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pattern = "{AAAA}-{MM}-{GG}_{NN}_{Nome}"
        let naming = ProjectNaming(pattern: pattern)
        let date = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 23)))
        let generatedName = try XCTUnwrap(naming.name(title: "Nuovo", date: date, existingNames: []))
        let legacyURL = root.appendingPathComponent("26_09_03_Storico")
        for name in [generatedName, legacyURL.lastPathComponent, "26_10_02_NonCatalogato", "Altre cartelle"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let manager = DataManager(defaults: defaults, backupDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(domain + "-backups"))
        manager.updateProjectNamingPattern(pattern)
        let old = VideoProject(name: legacyURL.lastPathComponent, path: legacyURL.path, date: date,
                               volumeIdentifier: "Macintosh HD", billingStatus: .billed, deadline: date,
                               isCompleted: true, comments: "Non perdere")
        manager.addProject(old)
        let scanner = FolderScanner(dataManager: manager)
        let operation = Task { await scanner.scanFolders([root], isSync: true) }
        defer { operation.cancel() }
        for _ in 0..<200 {
            if scanner.scanProgress == 1 && !scanner.isScanning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(scanner.scanProgress, 1)
        XCTAssertFalse(scanner.isScanning)
        XCTAssertEqual(Set(manager.projects.map(\.name)), Set([generatedName, old.name]))
        let restored = try XCTUnwrap(manager.projects.first { $0.id == old.id })
        XCTAssertFalse(restored.isMissing)
        XCTAssertEqual(restored.billingStatus, .billed)
        XCTAssertEqual(restored.comments, "Non perdere")
        XCTAssertEqual(restored.deadline, old.deadline)
        XCTAssertTrue(restored.isCompleted)
    }
}
