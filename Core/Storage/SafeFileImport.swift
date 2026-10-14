import Foundation

public enum SafeFileImport {
    public static func availableURL(name: String, in directory: URL) -> URL {
        let clean = URL(fileURLWithPath: name).lastPathComponent
        let initial = directory.appendingPathComponent(clean)
        let encrypted = initial.pathExtension == "vault"
        let original = encrypted ? initial.deletingPathExtension() : initial
        let ext = original.pathExtension + (encrypted ? ".vault" : "")
        let stem = original.deletingPathExtension().lastPathComponent
        var candidate = initial
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) (\(number))" + (ext.isEmpty ? "" : ".\(ext)"))
            number += 1
        }
        return candidate
    }

    /// Stage in the destination filesystem. Never delete an existing user file.
    public static func copy(_ source: URL, to destination: URL) throws {
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stage) }
        try FileManager.default.copyItem(at: source, to: stage)
        let expected = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard expected == (try stage.resourceValues(forKeys: [.fileSizeKey]).fileSize) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: stage, to: destination)
    }
}
