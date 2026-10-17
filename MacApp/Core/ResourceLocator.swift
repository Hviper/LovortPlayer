import Foundation

/// Resolves paths for Python scripts and user-writable runtime data.
public final class ResourceLocator: Sendable {
    public static let shared = ResourceLocator()

    public init() {}

    // MARK: - User-Writable Directories (Preserving existing paths & App Support)

    /// Standard Application Support directory for LovortMacSubtitleService.
    public static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("LovortMacSubtitleService", isDirectory: true)
    }

    /// User-writable virtual environment path inside Application Support.
    public static var managedVenvDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("venv", isDirectory: true)
    }

    /// Compatibility Token file: ~/.config/lovort-mac-subtitles/token
    public static var defaultTokenFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/lovort-mac-subtitles/token")
    }

    /// Compatibility Jobs directory: ~/.local/share/lovort-mac-subtitles/jobs
    public static var defaultJobsDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/lovort-mac-subtitles/jobs", isDirectory: true)
    }

    // MARK: - Resource Resolution (App Bundle and Dev Workspace)

    /// Resolves the root directory containing the Python service files (server.py, jobs.py, requirements.txt).
    public static func resolveServiceDirectory(sourceFilePath: String = #filePath) -> URL? {
        let fm = FileManager.default

        // 1. Check in App Bundle resources: Contents/Resources/MacSubtitleService
        if let bundleResource = Bundle.main.resourceURL?.appendingPathComponent("MacSubtitleService"),
           fm.fileExists(atPath: bundleResource.appendingPathComponent("server.py").path) {
            return bundleResource
        }

        // 2. Check directly in App Bundle resources root: Contents/Resources/server.py
        if let bundleResource = Bundle.main.resourceURL,
           fm.fileExists(atPath: bundleResource.appendingPathComponent("server.py").path) {
            return bundleResource
        }

        #if DEBUG
        // Development-only fallback. Release builds must use bundled resources.
        // 3. Check relative to current source file (development builds in repo)
        let sourceURL = URL(fileURLWithPath: sourceFilePath)
        let repoRoot = sourceURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let devServiceDir = repoRoot.appendingPathComponent("MacSubtitleService")
        if fm.fileExists(atPath: devServiceDir.appendingPathComponent("server.py").path) {
            return devServiceDir
        }

        // 4. Check relative to current working directory
        let cwdServiceDir = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("MacSubtitleService")
        if fm.fileExists(atPath: cwdServiceDir.appendingPathComponent("server.py").path) {
            return cwdServiceDir
        }
        #endif

        #if DEBUG
        // Development-only fallback for Xcode build products.
        var searchDir = Bundle.main.bundleURL
        for _ in 0..<6 {
            searchDir = searchDir.deletingLastPathComponent()
            let candidate = searchDir.appendingPathComponent("MacSubtitleService")
            if fm.fileExists(atPath: candidate.appendingPathComponent("server.py").path) {
                return candidate
            }
        }
        #endif

        return nil
    }

    /// Resolves the server.py file URL.
    public static func resolveServerPy(sourceFilePath: String = #filePath) -> URL? {
        resolveServiceDirectory(sourceFilePath: sourceFilePath)?.appendingPathComponent("server.py")
    }

    /// Resolves the jobs.py file URL.
    public static func resolveJobsPy(sourceFilePath: String = #filePath) -> URL? {
        resolveServiceDirectory(sourceFilePath: sourceFilePath)?.appendingPathComponent("jobs.py")
    }

    /// Resolves the requirements.txt file URL.
    public static func resolveRequirementsTxt(sourceFilePath: String = #filePath) -> URL? {
        resolveServiceDirectory(sourceFilePath: sourceFilePath)?.appendingPathComponent("requirements.txt")
    }

    /// Resolves the best available Python virtual environment:
    /// 1. Application Support managed venv (if bin/python exists)
    /// 2. Development repo venv (if MacSubtitleService/.venv/bin/python exists)
    public static func resolveActiveVenvURL(sourceFilePath: String = #filePath) -> URL {
        let fm = FileManager.default
        let managed = managedVenvDirectory
        if fm.isExecutableFile(atPath: managed.appendingPathComponent("bin/python").path) {
            return managed
        }

        #if DEBUG
        // A debug app bundle already contains service resources, so resolve the source
        // checkout directly instead of asking resolveServiceDirectory() and accidentally
        // looking for an intentionally unbundled .venv inside the app.
        let sourceURL = URL(fileURLWithPath: sourceFilePath)
        let repoRoot = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceVenv = repoRoot.appendingPathComponent("MacSubtitleService/.venv")
        if fm.isExecutableFile(atPath: sourceVenv.appendingPathComponent("bin/python").path) {
            return sourceVenv
        }

        let cwdVenv = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("MacSubtitleService/.venv")
        if fm.isExecutableFile(atPath: cwdVenv.appendingPathComponent("bin/python").path) {
            return cwdVenv
        }
        #endif

        // Default to managed location
        return managed
    }
}
