import XCTest
@testable import FolderFlow

final class CloudBackupTests: XCTestCase {
    private func snapshot(comments: String = "Note originali") -> CloudBackupSnapshot {
        let info = CatalogInfo(id: UUID(), name: "Backup fixture", createdAt: Date(), namingPattern: ProjectNaming.defaultPattern, colors: [:])
        let project = CatalogProject(id: UUID(), name: "26_10_01_Fixture", date: Date(), volumeName: "HD", sourceDeviceID: "Desktop", sourcePath: "/Volumes/HD/Fixture", folderSize: 42, folderContents: [], isAnalyzed: true, billingStatus: .billed, isCompleted: true, comments: comments)
        return CloudBackupSnapshot(catalog: StoredCatalog(info: info, projects: [project]), sourceDeviceID: "Desktop", capturedAt: Date())
    }
    private func info(_ encoded: EncodedCloudBackup, snapshot: CloudBackupSnapshot) -> CloudBackupInfo {
        CloudBackupInfo(id: UUID(), catalogID: snapshot.catalog.id, createdAt: Date(), rawSize: encoded.rawSize, compressedSize: encoded.data.count,
                        chunkCount: encoded.chunks.count, checksum: encoded.checksum, projectCount: snapshot.catalog.projects.count)
    }
    func testCompressedSnapshotPreservesOriginalCatalogAndStates() throws {
        let source = snapshot(), encoded = try CloudBackupCodec.encode(snapshot())
        let actual = try CloudBackupCodec.encode(source)
        let restored = try CloudBackupCodec.decode(actual.chunks, info: info(actual, snapshot: source))
        XCTAssertEqual(restored.catalog.id, source.catalog.id)
        XCTAssertTrue(restored.catalog.projects[0].isCompleted)
        XCTAssertEqual(restored.catalog.projects[0].billingStatus, .billed)
        XCTAssertEqual(restored.catalog.projects[0].sourcePath, source.catalog.projects[0].sourcePath)
        XCTAssertEqual(restored.catalog.projects[0].comments, "Note originali")
        XCTAssertLessThan(encoded.data.count, encoded.rawSize)
    }
    func testChunkingAndIntegrityRejectIncompleteCopies() throws {
        let random = Data((0..<900_000).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let source = snapshot(comments: random), encoded = try CloudBackupCodec.encode(source)
        XCTAssertGreaterThan(encoded.chunks.count, 1)
        let header = info(encoded, snapshot: source)
        let decoded = try CloudBackupCodec.decode(encoded.chunks, info: header)
        XCTAssertEqual(decoded.catalog.projects[0].comments, random)
        XCTAssertThrowsError(try CloudBackupCodec.decode(Array(encoded.chunks.dropLast()), info: header))
        var corrupted = encoded.chunks; corrupted[0][0] ^= 0xff
        XCTAssertThrowsError(try CloudBackupCodec.decode(corrupted, info: header))
    }
    func testDeclaredSizeLimitPreventsUnboundedDecompression() throws {
        let source = snapshot(), encoded = try CloudBackupCodec.encode(source)
        let header = CloudBackupInfo(id: UUID(), catalogID: source.catalog.id, createdAt: Date(), rawSize: CloudBackupCodec.maxRawSize + 1,
                                     compressedSize: encoded.data.count, chunkCount: encoded.chunks.count, checksum: encoded.checksum, projectCount: 1)
        XCTAssertThrowsError(try CloudBackupCodec.decode(encoded.chunks, info: header))
        XCTAssertEqual(CloudBackupCodec.retention, 60 * 24 * 60 * 60)
    }
}
