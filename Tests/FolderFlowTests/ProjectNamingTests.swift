import XCTest
@testable import FolderFlow

final class ProjectNamingTests: XCTestCase {
    private var date: Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 12))!
    }

    func testOriginalFormatAndMonthlyNumberingRemainDefault() {
        let naming = ProjectNaming()
        XCTAssertNil(naming.validationError)
        XCTAssertEqual(naming.name(title: "Campagna_Autunno", date: date,
                                   existingNames: ["26_10_08_Studio", "26_09_99_Settembre", "25_10_50_AnnoScorso"]),
                       "26_10_09_Campagna_Autunno")
        XCTAssertTrue(naming.matches("26_10_09_Campagna_Autunno"))
        XCTAssertEqual(naming.year(in: "26_10_09_Campagna_Autunno"), 2026)
    }

    func testEveryPresetGeneratesNamesItsScannerRecognizes() {
        for pattern in ProjectNaming.presets {
            let naming = ProjectNaming(pattern: pattern)
            XCTAssertNil(naming.validationError, pattern)
            let name = naming.name(title: "Ritratto – Città", date: date, existingNames: [])
            XCTAssertNotNil(name, pattern)
            XCTAssertTrue(naming.matches(name ?? ""), pattern)
            XCTAssertFalse(naming.matches("Una cartella qualsiasi"), pattern)
        }
    }

    func testCustomNameOrderLiteralRegexAndUnicode() {
        let naming = ProjectNaming(pattern: "Studio [A]. {Nome} - {AAAA}{MM}{GG} - {NN}")
        XCTAssertNil(naming.validationError)
        let value = naming.name(title: "Città_東京", date: date,
                                existingNames: ["Studio [A]. Vecchio - 20261023 - 04", "Studio [A]. Ieri - 20261022 - 99"])
        XCTAssertEqual(value, "Studio [A]. Città_東京 - 20261023 - 05")
        XCTAssertTrue(naming.matches(value!))
        XCTAssertFalse(naming.matches("Studio A! Film - 20261023 - 05"))
        XCTAssertEqual(naming.year(in: value!), 2026)
    }

    func testSerialCanGrowPast99And32BitBoundaries() {
        let naming = ProjectNaming(pattern: "{NN}_{Nome}")
        XCTAssertEqual(naming.name(title: "Film", date: date, existingNames: ["99_Test"]), "100_Film")
        XCTAssertTrue(naming.matches("100_Film"))
        XCTAssertEqual(naming.name(title: "Film", date: date, existingNames: ["2147483647_Test"]), "2147483648_Film")
        XCTAssertNil(naming.name(title: "Film", date: date, existingNames: ["\(Int.max)_Test"]))
    }

    func testOptionalCounterAndLiteralTokenInsideTitle() {
        let naming = ProjectNaming(pattern: "{AAAA}-{MM}-{GG}_{Nome}")
        XCTAssertEqual(naming.name(title: "Film {MM}", date: date, existingNames: []), "2026-10-23_Film {MM}")
        XCTAssertTrue(naming.matches("2026-10-23_Film {MM}"))
    }

    func testInvalidTemplatesAreRejected() {
        for invalid in ["", "{Nome}", "{AA}_{AAAA}_{Nome}", "{AA}_{XX}_{Nome}", "{NN}_{Nome}_{Nome}",
                        "{AA}_{MM}", "{AA}_{Nome", "{Nome}{NN}", "{AAAA}/{Nome}", "{Nome}\nFilm"] {
            let naming = ProjectNaming(pattern: invalid)
            XCTAssertNotNil(naming.validationError, invalid)
            XCTAssertNil(naming.name(title: "Film", date: date, existingNames: []), invalid)
        }
    }

    func testInvalidDatesAndPathComponentsAreRejected() {
        let naming = ProjectNaming(pattern: "{AAAA}-{MM}-{GG}_{Nome}")
        XCTAssertFalse(naming.matches("2026-02-30_Film"))
        XCTAssertFalse(naming.matches("2026-13-01_Film"))
        XCTAssertFalse(naming.matches("2026-00-01_Film"))
        XCTAssertTrue(naming.matches("2024-02-29_Film"))
        XCTAssertFalse(naming.matches("2025-02-29_Film"))
        for invalid in ["", "  ", "../escape", "a/b", "a:b", "a\\b", "a\0b", String(repeating: "x", count: 256)] {
            XCTAssertNil(naming.name(title: invalid, date: date, existingNames: []), invalid)
        }
    }
}
