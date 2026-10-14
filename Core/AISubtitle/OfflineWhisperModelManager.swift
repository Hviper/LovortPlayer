import Combine
import Foundation
import WhisperKit

private final class ModelPreparationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?

    func install(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ result: Result<URL, Error>) {
        lock.lock()
        if self.result != nil {
            lock.unlock()
            return
        }
        if let continuation {
            self.continuation = nil
            self.result = result
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.result = result
            lock.unlock()
        }
    }
}

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

struct OfflineModelDownloadMetrics: Equatable {
    let fraction: Double
    let completedBytes: Int64
    let totalBytes: Int64
}

@MainActor
public final class OfflineWhisperModelManager: ObservableObject {
    public static let shared = OfflineWhisperModelManager()

    @Published public private(set) var records: [OfflineWhisperModel: OfflineModelInstallRecord] = [:]

    private var preparationTasks: [OfflineWhisperModel: Task<URL, Error>] = [:]
    private var preparationTokens: [OfflineWhisperModel: UUID] = [:]
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
        if let existing = preparationTasks[model] { return try await waitForPreparation(existing) }

        try FileManager.default.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)
        update(model) { record in
            record.state = .downloading
            record.progress = 0
            record.completedBytes = 0
            record.totalBytes = max(record.totalBytes, model.estimatedSizeBytes)
            record.errorMessage = nil
        }

        let preparationToken = UUID()
        preparationTokens[model] = preparationToken
        let task = Task<URL, Error> { [weak self] in
            do {
                let folder = try await WhisperKit.download(
                    variant: model.rawValue,
                    downloadBase: Self.modelsDirectory,
                    useBackgroundSession: false,
                    progressCallback: { [weak self] progress in
                        Task { @MainActor in
                            guard let self,
                                  self.preparationTokens[model] == preparationToken else { return }
                            let metrics = Self.downloadMetrics(
                                fraction: progress.fractionCompleted,
                                model: model
                            )
                            self.update(model) { record in
                                guard record.state == .downloading else { return }
                                record.state = .downloading
                                record.progress = metrics.fraction
                                record.completedBytes = metrics.completedBytes
                                record.totalBytes = metrics.totalBytes
                            }
                        }
                    }
                )
                guard self?.preparationTokens[model] == preparationToken else {
                    throw CancellationError()
                }
                self?.update(model) { record in
                    record.state = .installed
                    record.progress = 1
                    record.completedBytes = self?.directorySize(folder) ?? record.completedBytes
                    record.totalBytes = max(record.completedBytes, record.totalBytes)
                    record.folderPath = folder.path
                    record.errorMessage = nil
                }
                return folder
            } catch {
                if self?.preparationTokens[model] == preparationToken {
                    self?.update(model) { record in
                        if error is CancellationError {
                            record.state = .notInstalled
                            record.progress = 0
                            record.completedBytes = 0
                        } else {
                            record.state = .failed
                            record.errorMessage = error.localizedDescription
                        }
                    }
                }
                throw error
            }
        }
        preparationTasks[model] = task
        Task { [weak self] in
            _ = await task.result
            guard self?.preparationTokens[model] == preparationToken else { return }
            self?.preparationTasks[model] = nil
            self?.preparationTokens[model] = nil
        }
        return try await waitForPreparation(task)
    }

    public func delete(_ model: OfflineWhisperModel) throws {
        guard !SubtitleTaskManager.shared.tasks.contains(where: { $0.phase.isActive && $0.model == model }) else {
            throw NSError(domain: "OfflineModelManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "该模型正在用于字幕任务，请先暂停或取消任务"])
        }
        preparationTasks[model]?.cancel()
        preparationTasks[model] = nil
        preparationTokens[model] = nil
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
            var record = records[model] ?? self.record(for: model)
            let recordedFolder = record.folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            if record.state == .installed,
               let recordedFolder,
               isUsableModelFolder(recordedFolder) {
                record.state = .installed
                record.progress = 1
                record.completedBytes = directorySize(recordedFolder)
                record.totalBytes = max(record.completedBytes, model.estimatedSizeBytes)
                record.errorMessage = nil
            } else if preparationTasks[model] != nil {
                record.state = .downloading
            } else if let discovered = discoverInstalledFolder(for: model) {
                record.state = .installed
                record.progress = 1
                record.folderPath = discovered.path
                record.completedBytes = directorySize(discovered)
                record.totalBytes = max(record.completedBytes, record.totalBytes)
                record.errorMessage = nil
            } else if record.state == .downloading || record.state == .installed {
                record.state = .notInstalled
                record.progress = 0
                record.completedBytes = 0
                record.folderPath = nil
            }
            records[model] = record
        }
        saveRecords()
    }

    static func downloadMetrics(fraction: Double, model: OfflineWhisperModel) -> OfflineModelDownloadMetrics {
        let normalized = fraction.isFinite ? min(1, max(0, fraction)) : 0
        return OfflineModelDownloadMetrics(
            fraction: normalized,
            completedBytes: Int64(Double(model.estimatedSizeBytes) * normalized),
            totalBytes: model.estimatedSizeBytes
        )
    }

    static func modelFolderName(_ folderName: String, matches model: OfflineWhisperModel) -> Bool {
        folderName == model.rawValue || folderName == "openai_whisper-\(model.rawValue)"
    }

    static func containsRequiredModelComponents(fileNames: [String]) -> Bool {
        let requiredPrefixes = ["MelSpectrogram.", "AudioEncoder.", "TextDecoder."]
        return requiredPrefixes.allSatisfy { prefix in
            fileNames.contains { $0.hasPrefix(prefix) }
        }
    }

    private func waitForPreparation(_ task: Task<URL, Error>) async throws -> URL {
        let waiter = ModelPreparationWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                Task.detached {
                    waiter.finish(await task.result)
                }
            }
        } onCancel: {
            waiter.finish(.failure(CancellationError()))
        }
    }

    private func discoverInstalledFolder(for model: OfflineWhisperModel) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: Self.modelsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            guard Self.modelFolderName(url.lastPathComponent, matches: model),
                  isUsableModelFolder(url) else { continue }
            return url
        }
        return nil
    }

    private func isUsableModelFolder(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let enumerator = FileManager.default.enumerator(
                  at: url,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              ) else { return false }
        let names = enumerator.compactMap { ($0 as? URL)?.lastPathComponent }
        return Self.containsRequiredModelComponents(fileNames: names)
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
