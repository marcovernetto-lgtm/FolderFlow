import XCTest
@testable import FolderFlow

final class DiskUsageTests: XCTestCase {
    @MainActor
    func testChartRanksByPercentageAcrossDifferentDiskSizes() throws {
        let domain = "FolderFlowUsage." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let manager = DataManager(defaults: defaults, backupDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(domain))
        let gib = 1024.0 * 1024.0 * 1024.0
        manager.connectedVolumes = [("4TB", Int64(4_000_000_000_000)), ("6TB_F", Int64(6_000_000_000_000)), ("6TB_C", Int64(6_000_000_000_000))].map {
            MountedVolumeInfo(name: $0.0, url: URL(fileURLWithPath: "/Volumes/" + $0.0), totalCapacityGB: 999, usedCapacityGB: 0, totalBytes: $0.1)
        }
        func project(_ volume: String, _ bytes: Double) -> VideoProject {
            VideoProject(name: "Fixture", path: "/tmp/fixture", date: Date(), volumeIdentifier: volume, folderSize: bytes / gib)
        }
        let projects = [project("6TB_F", 6_000_000_000_000 * 0.65), project("6TB_C", 6_000_000_000_000 * 0.54),
                        project("4TB", 4_000_000_000_000 * 0.40), project("4TB", 4_000_000_000_000 * 0.27)]
        let usage = manager.diskUsage(for: projects)
        XCTAssertEqual(usage.map(\.volume), ["4TB", "6TB_F", "6TB_C"])
        XCTAssertEqual(try XCTUnwrap(usage[0].percent), 67, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(usage[1].percent), 65, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(usage[2].percent), 54, accuracy: 0.0001)
        XCTAssertLessThan(usage[0].sizeGB, usage[1].sizeGB)
        XCTAssertEqual(manager.diskUsage(for: Array(projects.prefix(1))).map(\.volume), ["6TB_F"])
    }

    @MainActor
    func testDisconnectedCapacityEstimatesAndUnknownDisks() throws {
        let domain = "FolderFlowUsage." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let manager = DataManager(defaults: defaults, backupDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(domain))
        manager.connectedVolumes = []
        let gib = 1024.0 * 1024.0 * 1024.0
        let projects = ["6TB_F", "16TB_Archive", "Unknown"].map {
            VideoProject(name: "Fixture", path: "/tmp/fixture", date: Date(), volumeIdentifier: $0, folderSize: 3_000_000_000_000 / gib)
        }
        let usage = manager.diskUsage(for: projects)
        XCTAssertEqual(usage.map(\.volume), ["6TB_F", "16TB_Archive", "Unknown"])
        XCTAssertEqual(try XCTUnwrap(usage[0].percent), 50, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(usage[1].percent), 18.75, accuracy: 0.0001)
        XCTAssertNil(usage[2].percent)
        XCTAssertTrue(manager.diskUsage(for: []).isEmpty)
    }
}
