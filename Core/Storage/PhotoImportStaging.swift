import Foundation

public enum PhotoImportStaging {
    private static var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("PhotoImports", isDirectory: true) }
    public static func copy(_ source: URL) throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        #endif
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        do { try SafeFileImport.copy(source, to: destination); return destination }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    public static func release(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              UUID(uuidString: directory.lastPathComponent) != nil else { return }
        try? FileManager.default.removeItem(at: directory)
    }
    /// Call once before this process starts any photo transfers.
    public static func removeAbandoned() {
        guard let directories = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for directory in directories where UUID(uuidString: directory.lastPathComponent) != nil { try? FileManager.default.removeItem(at: directory) }
    }
}
