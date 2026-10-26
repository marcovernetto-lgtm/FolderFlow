import XCTest
@testable import FolderFlow

final class CatalogTransferTests: XCTestCase {
    func testLegacyJSONPreservesStatusesWithBothDateEncodings() throws {
        let project = VideoProject(name: "26_10_01_Legacy", path: "/Volumes/Fixture/26_10_01_Legacy", date: Date(timeIntervalSince1970: 1_700_000_000),
                                   volumeIdentifier: "Fixture", folderSize: 42, billingStatus: .billed, isCompleted: true, comments: "Stati originali")
        let original = AppData(projects: [project], volumeColors: ["Fixture": ColorRGB(red: 0.2, green: 0.6, blue: 0.4)])
        for isoDates in [false, true] {
            let encoder = JSONEncoder()
            if isoDates { encoder.dateEncodingStrategy = .iso8601 }
            let transfer = try CatalogTransfer.decode(encoder.encode(original), name: "Vecchio catalogo", deviceID: "This-Mac")
            let imported = try XCTUnwrap(transfer.catalog.projects.first)
            XCTAssertEqual(imported.id, project.id)
            XCTAssertTrue(imported.isCompleted)
            XCTAssertEqual(imported.billingStatus, .billed)
            XCTAssertEqual(imported.comments, project.comments)
            XCTAssertEqual(transfer.catalog.info.namingPattern, ProjectNaming.defaultPattern)
            XCTAssertEqual(transfer.sourceDeviceID, "This-Mac")
        }
    }

    func testInvalidFilesAndDuplicateProjectIDsAreRejected() throws {
        XCTAssertThrowsError(try CatalogTransfer.decode(Data("{}".utf8), name: "Invalid", deviceID: "A"))
        let project = VideoProject(name: "Fixture", path: "/fixture", date: Date(), volumeIdentifier: "HD", folderSize: 1)
        let data = AppData(projects: [project, project], volumeColors: [:])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        XCTAssertThrowsError(try CatalogTransfer.decode(encoder.encode(data), name: "Duplicate", deviceID: "A"))
    }
}
