import XCTest
import SwiftUI
@testable import FolderFlow

final class VolumeColorTests: XCTestCase {
    private func assertColor(_ actual: Color, equals expected: Color, file: StaticString = #filePath, line: UInt = #line) {
        let a = ColorRGB.fromColor(actual), b = ColorRGB.fromColor(expected)
        XCTAssertEqual(a.red, b.red, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(a.green, b.green, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(a.blue, b.blue, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(a.alpha, b.alpha, accuracy: 0.0001, file: file, line: line)
    }

    @MainActor
    func testManualColorSurvivesRefreshDisconnectAndRestart() throws {
        let domain = "FolderFlowColors." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let manager = DataManager(defaults: defaults, backupDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(domain + "-backups"))
        let disk = MountedVolumeInfo(name: "Fixture disk", url: URL(fileURLWithPath: "/Volumes/Fixture disk"), totalCapacityGB: 1000, usedCapacityGB: 100)
        manager.connectedVolumes = [disk]
        manager.monitoredPaths = [disk.url.path]
        manager.assignVolumeColors()
        let chosen = StudioTheme.volumeColor(Color(red: 0.84, green: 0.43, blue: 0.21))
        manager.setVolumeColor(chosen, for: disk.name)
        manager.connectedVolumes = []
        manager.assignVolumeColors()
        manager.connectedVolumes = [disk]
        manager.assignVolumeColors()
        assertColor(manager.getVolumeColor(for: disk.name), equals: chosen)
        XCTAssertEqual(manager.monitoredPaths, [disk.url.path])
        let restored = DataManager(defaults: defaults, backupDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(domain + "-backups"))
        assertColor(restored.getVolumeColor(for: disk.name), equals: chosen)
        restored.clearAllProjects()
        assertColor(restored.getVolumeColor(for: disk.name), equals: chosen)
        let saved = try JSONDecoder().decode([String: ColorRGB].self, from: XCTUnwrap(defaults.data(forKey: "VolumeColors")))
        assertColor(try XCTUnwrap(saved[disk.name]).toColor(), equals: chosen)
    }

    @MainActor
    func testCustomColorsRoundTripThroughExistingCatalogExportAndImport() throws {
        let domain = "FolderFlowColors." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let manager = DataManager(defaults: defaults, backupDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(domain + "-backups"))
        let chosen = StudioTheme.volumeColor(Color(red: 0.2, green: 0.7, blue: 0.6))
        manager.setVolumeColor(chosen, for: "Offline fixture")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertTrue(manager.exportToFile(at: file.path))
        manager.setVolumeColor(.orange, for: "Offline fixture")
        XCTAssertTrue(manager.importFromFile(at: file.path))
        manager.assignVolumeColors()
        assertColor(manager.getVolumeColor(for: "Offline fixture"), equals: chosen)
        XCTAssertTrue(manager.projects.isEmpty)
    }

    @MainActor
    func testLegacyPaletteMigratesWithoutTurningDisksGray() throws {
        let domain = "FolderFlowColors." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(try JSONEncoder().encode(["Macintosh HD": "gray"]), forKey: "VolumeColors")
        let manager = DataManager(defaults: defaults, backupDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(domain + "-backups"))
        XCTAssertNil(manager.errorMessage)
        let saved = try JSONDecoder().decode([String: ColorRGB].self, from: XCTUnwrap(defaults.data(forKey: "VolumeColors")))
        XCTAssertFalse(saved.isEmpty)
        for color in saved.values {
            XCTAssertGreaterThan(max(color.red, color.green, color.blue) - min(color.red, color.green, color.blue), 0.05)
        }
        let count = manager.volumeColors.count
        manager.setVolumeColor(.red, for: "")
        XCTAssertEqual(manager.volumeColors.count, count)
    }
}
