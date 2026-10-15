import Foundation
import ZIPFoundation

public struct LibraryBackupManifest: Codable, Sendable {
    public let formatVersion: Int
    public let createdAt: Date
    public let appVersion: String
    public let vaultSecrets: BackupVaultSecrets
}

@MainActor
public final class LibraryBackupManager {
    public static let shared = LibraryBackupManager()
    private let fm = FileManager.default
    private init() {}

    public func createBackup(password: String) async throws -> URL {
        guard password.utf8.count >= 8 else { throw Self.failure("备份密码至少需要 8 个字符") }
        guard !MediaLibraryManager.shared.isImporting else { throw Self.failure("请等视频导入完成后再备份") }
        let secrets = try VaultManager.shared.exportBackupSecrets()
        let activeTaskIDs = SubtitleTaskManager.shared.tasks.filter { $0.phase.isActive }.map(\.id)
        for id in activeTaskIDs { SubtitleTaskManager.shared.pause(id) }
        defer { for id in activeTaskIDs { SubtitleTaskManager.shared.resume(id) } }
        SubtitleTaskManager.shared.flushTasks()
        PlaybackHistoryManager.shared.flush()
        MediaIdentityStore.shared.flush()

        let root = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BackupExports", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: root.path)
        #endif
        let work = root.appendingPathComponent(".work-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let manifest = LibraryBackupManifest(formatVersion: 1, createdAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            vaultSecrets: secrets)
        let manifestURL = work.appendingPathComponent("Manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        let preferencesURL = work.appendingPathComponent("Preferences.plist")
        try Self.exportPreferences().write(to: preferencesURL, options: .atomic)
        let archiveURL = work.appendingPathComponent("Library.zip")
        let output = root.appendingPathComponent("LovortPlayer-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).lovortbackup")
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        do {
            try await Task.detached(priority: .utility) {
                try Self.makeArchive(at: archiveURL, documents: documents, support: support,
                                     manifest: manifestURL, preferences: preferencesURL)
                try BackupCryptor.encrypt(source: archiveURL, destination: output, password: password)
            }.value
            return output
        } catch { try? fm.removeItem(at: output); throw error }
    }

    /// Restore only into an empty library; existing videos and vault keys are never replaced.
    public func restoreBackup(from source: URL, password: String) async throws {
        guard !MediaLibraryManager.shared.isImporting else { throw Self.failure("请等视频导入完成后再恢复") }
        guard !hasExistingUserFiles() else { throw Self.failure("恢复只支持空媒体库，请先在新安装的 App 中操作") }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let root = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BackupRestore", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: root.path)
        #endif
        defer { try? fm.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("Library.zip")
        let extracted = root.appendingPathComponent("Extracted", isDirectory: true)
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let manifest = try await Task.detached(priority: .utility) { () -> LibraryBackupManifest in
            try BackupCryptor.decrypt(source: source, destination: archiveURL, password: password)
            try Self.validateArchive(at: archiveURL)
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
            try FileManager.default.unzipItem(at: archiveURL, to: extracted)
            let manifestData = try Data(contentsOf: extracted.appendingPathComponent("Manifest.json"))
            let manifest = try JSONDecoder().decode(LibraryBackupManifest.self, from: manifestData)
            guard manifest.formatVersion == 1 else { throw Self.failure("不支持此备份格式") }
            return manifest
        }.value
        guard !hasExistingUserFiles() else { throw Self.failure("恢复期间媒体库发生了变化，请重新操作") }

        let preferences = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: extracted.appendingPathComponent("Preferences.plist")), options: [], format: nil
        ) as? [String: Any] ?? [:]
        let restored = try Self.restoreFiles(from: extracted, documents: documents, support: support, rollbackRoot: root)
        do {
            try VaultManager.shared.restoreBackupSecrets(manifest.vaultSecrets)
        } catch {
            Self.rollback(restored)
            throw error
        }
        for (key, value) in preferences where Self.isAllowedPreference(key) {
            UserDefaults.standard.set(value, forKey: key)
        }
        UserDefaults.standard.synchronize()
    }

    private func hasExistingUserFiles() -> Bool {
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let enumerator = fm.enumerator(at: documents, includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
        for case let file as URL in enumerator {
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { return true }
        }
        return false
    }

    private nonisolated static func makeArchive(at output: URL, documents: URL, support: URL,
                                                 manifest: URL, preferences: URL) throws {
        let archive = try Archive(url: output, accessMode: .create)
        try archive.addEntry(with: "Manifest.json", fileURL: manifest)
        try archive.addEntry(with: "Preferences.plist", fileURL: preferences)
        try addFiles(from: documents, prefix: "Documents", to: archive)
        for name in ["MediaIndex.json", "Playlists.json", "SubtitleCache", "SubtitleTasks"] {
            let source = support.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: source.path) {
                try addFiles(from: source, prefix: "Support/\(name)", to: archive)
            }
        }
    }

    private nonisolated static func addFiles(from source: URL, prefix: String, to archive: Archive) throws {
        let fm = FileManager.default
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true { throw failure("备份中包含不支持的链接文件") }
        if values.isRegularFile == true {
            try archive.addEntry(with: prefix, fileURL: source)
            return
        }
        guard values.isDirectory == true,
              let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return }
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            let details = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if details.isSymbolicLink == true { throw failure("备份中包含不支持的链接文件") }
            guard details.isRegularFile == true else { continue }
            let relative = String(file.path.dropFirst(source.path.count + 1))
            try archive.addEntry(with: prefix + "/" + relative, fileURL: file)
        }
    }

    private nonisolated static func validateArchive(at url: URL) throws {
        let archive = try Archive(url: url, accessMode: .read)
        var total: UInt64 = 0
        var entries = 0
        var manifestCount = 0
        var preferencesCount = 0
        for entry in archive {
            try Task.checkCancellation()
            let path = entry.path
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
                throw failure("备份包含不安全的路径")
            }
            guard path == "Manifest.json" || path == "Preferences.plist" ||
                  path.hasPrefix("Documents/") || path.hasPrefix("Support/") else { throw failure("备份包含未知文件") }
            if path.hasPrefix("Support/") {
                guard ["Support/MediaIndex.json", "Support/Playlists.json"].contains(path) ||
                    path.hasPrefix("Support/SubtitleCache/") || path.hasPrefix("Support/SubtitleTasks/") else {
                    throw failure("备份包含未知的应用数据")
                }
            }
            if path == "Manifest.json" { manifestCount += 1 }
            if path == "Preferences.plist" { preferencesCount += 1 }
            guard entry.type != .symlink else { throw failure("备份包含不安全的链接") }
            let next = total.addingReportingOverflow(entry.uncompressedSize)
            guard !next.overflow else { throw failure("备份文件过大") }
            total = next.partialValue
            entries += 1
            guard entries <= 100_000, total <= 500_000_000_000 else { throw failure("备份文件过大") }
        }
        guard manifestCount == 1, preferencesCount == 1 else { throw failure("备份缺少必要信息") }
    }

    private struct RestoredFiles {
        var created: [URL] = []
        var previous: [(target: URL, backup: URL)] = []
    }

    private nonisolated static func restoreFiles(from extracted: URL, documents: URL, support: URL,
                                                  rollbackRoot: URL) throws -> RestoredFiles {
        let fm = FileManager.default
        var restored = RestoredFiles()
        do {
            for (folder, destination) in [("Documents", documents), ("Support", support)] {
                let source = extracted.appendingPathComponent(folder, isDirectory: true)
                guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { continue }
                for case let file as URL in enumerator {
                    try Task.checkCancellation()
                    let details = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard details.isSymbolicLink != true else { throw failure("备份包含不安全的链接") }
                    guard details.isRegularFile == true else { continue }
                    let relative = String(file.path.dropFirst(source.path.count + 1))
                    let target = destination.appendingPathComponent(relative)
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: target.path) {
                        guard folder == "Support" else { throw failure("目标文件已存在：\(relative)") }
                        let old = rollbackRoot.appendingPathComponent("OldSupport", isDirectory: true).appendingPathComponent(relative)
                        try fm.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.moveItem(at: target, to: old)
                        restored.previous.append((target, old))
                    }
                    try fm.copyItem(at: file, to: target)
                    restored.created.append(target)
                    #if os(iOS)
                    try? fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: target.path)
                    #endif
                }
            }
            return restored
        } catch {
            rollback(restored)
            throw error
        }
    }

    private nonisolated static func rollback(_ restored: RestoredFiles) {
        let fm = FileManager.default
        for url in restored.created.reversed() { try? fm.removeItem(at: url) }
        for old in restored.previous.reversed() { try? fm.moveItem(at: old.backup, to: old.target) }
    }

    private static func exportPreferences() throws -> Data {
        let saved = UserDefaults.standard.dictionaryRepresentation().filter { isAllowedPreference($0.key) }
        return try PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0)
    }
    private nonisolated static func isAllowedPreference(_ key: String) -> Bool {
        key.hasPrefix("settings.") || key.hasPrefix("subtitle.") || key == "library.sort" ||
        ["LovortPlaybackHistoryRecords", "LovortPlayedDates", "LovortSelectedAIModelID",
         "LovortSubtitleEngine", "LovortOfflineWhisperModel", "LovortTranslationProvider",
         "LovortGPTSubtitleEnhancement", "LovortAzureTranslatorRegion"].contains(key) ||
        (key.hasPrefix("LovortTranslation.") && !key.lowercased().contains("key"))
    }
    private nonisolated static func failure(_ message: String) -> NSError {
        NSError(domain: "LovortBackup", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
