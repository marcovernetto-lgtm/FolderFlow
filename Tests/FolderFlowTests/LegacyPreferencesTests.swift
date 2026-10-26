import XCTest
@testable import FolderFlow

final class LegacyPreferencesTests: XCTestCase {
    func testMigrationBacksUpOriginalDataPreservesChoicesAndRunsOnlyOnce() throws {
        let defaults = UserDefaults(suiteName: "FolderFlowMigrationTests." + UUID().uuidString)!
        let target = "FolderFlow.New." + UUID().uuidString
        let source = "FolderFlow.LegacyFixture." + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: source)
            defaults.removePersistentDomain(forName: target)
            try? FileManager.default.removeItem(at: root)
        }
        let bytes = Data("original catalog bytes".utf8)
        defaults.setPersistentDomain(["SavedProjects": bytes, "MonitoredPaths": Data([1,2]), "HideDockIcon": true,
                                      "ProjectNamingPattern": "{AAAA}_{Nome}", "unrelated": "skip"], forName: source)
        defaults.setPersistentDomain(["HideDockIcon": false], forName: target)
        try LegacyPreferences.migrate(defaults: defaults, domain: target, backupDirectory: root, legacyDomain: source)
        let migrated = defaults.persistentDomain(forName: target)!
        XCTAssertEqual(migrated["SavedProjects"] as? Data, bytes)
        XCTAssertEqual(migrated["HideDockIcon"] as? Bool, false)
        XCTAssertNil(migrated["unrelated"])
        XCTAssertEqual(defaults.persistentDomain(forName: source)?["SavedProjects"] as? Data, bytes)
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        let copy = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: backups[0]), format: nil) as? [String: Any])
        XCTAssertEqual(copy["SavedProjects"] as? Data, bytes)
        try LegacyPreferences.migrate(defaults: defaults, domain: target, backupDirectory: root, legacyDomain: source)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
    }

    func testExistingNewCatalogIsNotMixedWithLegacyCatalogAndBackupFailureDoesNotMarkMigrationDone() throws {
        let defaults = UserDefaults(suiteName: "FolderFlowMigrationTests." + UUID().uuidString)!
        let target = "FolderFlow.New." + UUID().uuidString
        let source = "FolderFlow.LegacyFixture." + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: source)
            defaults.removePersistentDomain(forName: target)
            try? FileManager.default.removeItem(at: root)
        }
        defaults.setPersistentDomain(["SavedProjects": Data([1]), "MonitoredPaths": Data([2])], forName: source)
        defaults.setPersistentDomain(["SavedProjects": Data([3])], forName: target)
        try Data([0]).write(to: root)
        XCTAssertThrowsError(try LegacyPreferences.migrate(defaults: defaults, domain: target, backupDirectory: root, legacyDomain: source))
        XCTAssertNil(defaults.persistentDomain(forName: target)?[LegacyPreferences.marker])
        try FileManager.default.removeItem(at: root)
        try LegacyPreferences.migrate(defaults: defaults, domain: target, backupDirectory: root, legacyDomain: source)
        XCTAssertEqual(defaults.persistentDomain(forName: target)?["SavedProjects"] as? Data, Data([3]))
        XCTAssertNil(defaults.persistentDomain(forName: target)?["MonitoredPaths"])
    }
    @MainActor
    func testFailedStartupMigrationCannotSaveAnEmptyCatalog() throws {
        let domain = "FolderFlowMigrationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        let original = Data("preserved original catalog".utf8)
        defaults.set(original, forKey: "SavedProjects")
        let manager = DataManager(defaults: defaults, backupDirectory: root.appendingPathComponent("backups"), startupError: "Fixture: migration failed")
        XCTAssertTrue(manager.storageReadOnly)
        let workspace = CatalogWorkspace(manager: manager, cloud: CloudService(configure: false), root: root.appendingPathComponent("catalogs"), deviceID: "fixture")
        XCTAssertTrue(workspace.readOnly)
        XCTAssertNil(workspace.active)
        XCTAssertEqual(defaults.data(forKey: "SavedProjects"), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("catalogs/local.json").path))
    }

}
