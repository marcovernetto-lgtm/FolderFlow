import XCTest
@testable import FolderFlow

final class SecureCopyDownloadTests: XCTestCase {
    func testSelectsOfficialDMGForArchitectureAndRejectsOtherHosts() throws {
        let data = Data(#"{"assets":[{"name":"SecureCopy-arm64.dmg","browser_download_url":"https://evil.example/marcovernetto-lgtm/SecureCopy/releases/download/v1/bad.dmg"},{"name":"SecureCopy-x64.dmg","browser_download_url":"https://github.com/marcovernetto-lgtm/SecureCopy/releases/download/v1/intel.dmg"},{"name":"SecureCopy-arm64.zip","browser_download_url":"https://github.com/marcovernetto-lgtm/SecureCopy/releases/download/v1/arm.zip"},{"name":"SecureCopy-arm64.dmg","browser_download_url":"https://github.com/marcovernetto-lgtm/SecureCopy/releases/download/v1/arm.dmg"}]}"#.utf8)
        let release = try JSONDecoder().decode(SecureCopyRelease.self, from: data)
        XCTAssertEqual(release.downloadURL(architecture: "arm64")?.lastPathComponent, "arm.dmg")
        XCTAssertEqual(release.downloadURL(architecture: "x64")?.lastPathComponent, "intel.dmg")
        XCTAssertNil(release.downloadURL(architecture: "unsupported"))
        XCTAssertNil(SecureCopyRelease(assets: []).downloadURL(architecture: "arm64"))
    }
}
