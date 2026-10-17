import XCTest
@testable import LovortMacSubtitleService

final class ResourceLocatorTests: XCTestCase {

    func testUserDataDirectoriesAreOutsideAppBundle() {
        let appSupport = ResourceLocator.applicationSupportDirectory
        let venv = ResourceLocator.managedVenvDirectory
        let token = ResourceLocator.defaultTokenFileURL
        let jobs = ResourceLocator.defaultJobsDirectoryURL

        // Ensure none of them point inside .app bundle
        XCTAssertFalse(appSupport.path.contains(".app/"))
        XCTAssertFalse(venv.path.contains(".app/"))
        XCTAssertFalse(token.path.contains(".app/"))
        XCTAssertFalse(jobs.path.contains(".app/"))

        // Ensure token and jobs match compatibility paths
        XCTAssertTrue(token.path.hasSuffix(".config/lovort-mac-subtitles/token"))
        XCTAssertTrue(jobs.path.hasSuffix(".local/share/lovort-mac-subtitles/jobs"))
        XCTAssertTrue(venv.path.contains("Application Support/LovortMacSubtitleService/venv"))
    }

    func testResolveServiceDirectoryFromSource() {
        // Test resolving relative to this source file
        let serviceDir = ResourceLocator.resolveServiceDirectory()
        XCTAssertNotNil(serviceDir)
        if let dir = serviceDir {
            let serverPy = dir.appendingPathComponent("server.py")
            let jobsPy = dir.appendingPathComponent("jobs.py")
            let reqs = dir.appendingPathComponent("requirements.txt")

            XCTAssertTrue(FileManager.default.fileExists(atPath: serverPy.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: jobsPy.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: reqs.path))
        }
    }
}
