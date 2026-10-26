import XCTest
@testable import FolderFlow

final class SharedPreferencesTests: XCTestCase {
    func testLegacyQueueObjectsRemainReadable() throws {
        let catalog = UUID(), project = UUID()
        let data = try JSONSerialization.data(withJSONObject: ["catalogID": catalog.uuidString, "projectID": project.uuidString])
        let object = try CatalogArchive.decodeValue(CatalogObject.self, data)
        XCTAssertEqual(object, CatalogObject(catalogID: catalog, projectID: project))
        XCTAssertEqual(try CatalogArchive.decodeValue(CatalogObject.self, CatalogArchive.encodeValue(object)), object)
        XCTAssertEqual(try CatalogArchive.decodeValue(CatalogObject.self, CatalogArchive.encodeValue(CatalogObject.preferences)), .preferences)
    }
    func testPreferencesSurviveOfflineQueueAndConflictResolution() throws {
        var archive = CatalogArchive()
        let local = SharedAppPreferences(launchAtLogin: true, hideDockIcon: false)
        archive.preferences = local
        archive.enqueue(.preferences, payload: try CatalogArchive.encodeValue(local))
        archive = try CatalogArchive.decodeValue(CatalogArchive.self, CatalogArchive.encodeValue(archive))
        let remote = CatalogRemoteValue(object: .preferences, revision: 2, mutationID: UUID(), payload: try CatalogArchive.encodeValue(SharedAppPreferences(launchAtLogin: false, hideDockIcon: true)))
        try archive.receive(remote)
        XCTAssertEqual(archive.preferences, local)
        archive.conflicts[remote.object.key] = CatalogConflict(remote: remote)
        try archive.resolve(remote.object.key, keepLocal: false)
        XCTAssertEqual(archive.preferences?.hideDockIcon, true)
        XCTAssertTrue(archive.pending.isEmpty)
        XCTAssertEqual(archive.revisions[remote.object.key], 2)
    }
}
