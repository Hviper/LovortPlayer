import Combine
import Foundation
import WhisperKit

public enum OfflineModelInstallState: String, Codable, Sendable {
    case notInstalled
    case downloading
    case installed
    case failed
}

public struct OfflineModelInstallRecord: Codable, Sendable {
    public var state: OfflineModelInstallState
    public var progress: Double
    public var completedBytes: Int64
    public var totalBytes: Int64
    public var folderPath: String?
    public var errorMessage: String?
}

@MainActor
public final class OfflineWhisperModelManager: ObservableObject {
    public static let shared = OfflineWhisperModelManager()

    @Published public private(set) var records: [OfflineWhisperModel: OfflineModelInstallRecord] = [:]

    private var preparationTasks: [OfflineWhisperModel: Task<URL, Error>] = [:]
    private let defaultsKey = "LovortOfflineWhisperModelRecords"

    public static var modelsDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("WhisperModels", isDirectory: true)
    }

    private init() {
        loadRecords()
        refreshInstalledState()
    }

    public func record(for model: OfflineWhisperModel) -> OfflineModelInstallRecord {
        records[model] ?? OfflineModelInstallRecord(
            state: .notInstalled,
            progress: 0,
            completedBytes: 0,
            totalBytes: model.estimatedSizeBytes,
            folderPath: nil,
            errorMessage: nil
        )
    }

    public func installedFolder(for model: OfflineWhisperModel) -> URL? {
        let record = record(for: model)
        guard record.state == .installed, let path = record.folderPath else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func beginDownload(_ model: OfflineWhisperModel) {
        Task {
            do {
                _ = try await prepare(model)
            } catch {
                // The published record carries the actionable error for the UI.
            }
        }
    }

    public func prepare(_ model: OfflineWhisperModel) async throws -> URL {
        if let installed = installedFolder(for: model) { return installed }
        if let existing = preparationTasks[model] { return try await existing.value }

        try FileManager.default.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)
        update(model) { record in
            record.state = .downloading
            record.progress = 0
            record.completedBytes = 0
            record.totalBytes = max(record.totalBytes, model.estimatedSizeBytes)
            record.errorMessage = nil
        }

        let task = Task<URL, Error> {
            try await WhisperKit.download(
                variant: model.rawValue,
                downloadBase: Self.modelsDirectory,
                useBackgroundSession: true,
                progressCallback: { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        self.update(model) { record in
                            record.state = .downloading
                            record.progress = progress.fractionCompleted.isFinite
                                ? min(1, max(0, progress.fractionCompleted))
                                : record.progress
                            record.completedBytes = progress.completedUnitCount
                            if progress.totalUnitCount > 0 { record.totalBytes = progress.totalUnitCount }
                        }
                    }
                }
            )
        }
        preparationTasks[model] = task

        do {
            let folder = try await task.value
            preparationTasks[model] = nil
            update(model) { record in
                record.state = .installed
                record.progress = 1
                record.completedBytes = directorySize(folder)
                record.totalBytes = max(record.completedBytes, record.totalBytes)
                record.folderPath = folder.path
                record.errorMessage = nil
            }
            return folder
        } catch {
            preparationTasks[model] = nil
            update(model) { record in
                record.state = .failed
                record.errorMessage = error.localizedDescription
            }
            throw error
        }
    }

    public func delete(_ model: OfflineWhisperModel) throws {
        guard !SubtitleTaskManager.shared.tasks.contains(where: { $0.phase.isActive && $0.model == model }) else {
            throw NSError(domain: "OfflineModelManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "该模型正在用于字幕任务，请先暂停或取消任务"])
        }
        preparationTasks[model]?.cancel()
        preparationTasks[model] = nil
        if let path = record(for: model).folderPath {
            let target = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            let root = Self.modelsDirectory.standardizedFileURL
            guard target.path.hasPrefix(root.path + "/") else {
                throw NSError(domain: "OfflineModelManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "模型目录校验失败，未执行删除"])
            }
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
        }
        records[model] = OfflineModelInstallRecord(
            state: .notInstalled,
            progress: 0,
            completedBytes: 0,
            totalBytes: model.estimatedSizeBytes,
            folderPath: nil,
            errorMessage: nil
        )
        saveRecords()
    }

    public func refreshInstalledState() {
        for model in OfflineWhisperModel.allCases {
            guard var record = records[model] else { continue }
            if record.state == .downloading { record.state = .notInstalled }
            if record.state == .installed,
               let path = record.folderPath,
               !FileManager.default.fileExists(atPath: path) {
                record.state = .notInstalled
                record.progress = 0
                record.completedBytes = 0
                record.folderPath = nil
            }
            records[model] = record
        }
        saveRecords()
    }

    private func update(_ model: OfflineWhisperModel, _ mutation: (inout OfflineModelInstallRecord) -> Void) {
        var record = self.record(for: model)
        mutation(&record)
        records[model] = record
        saveRecords()
    }

    private func loadRecords() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: OfflineModelInstallRecord].self, from: data) else { return }
        records = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
            OfflineWhisperModel(rawValue: key).map { ($0, value) }
        })
    }

    private func saveRecords() {
        let encoded = Dictionary(uniqueKeysWithValues: records.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encoded) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
