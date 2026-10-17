import Foundation
import AppKit
import Combine

@MainActor
public final class JobStoreMonitor: ObservableObject {
    public static let shared = JobStoreMonitor()

    @Published public private(set) var jobs: [TranscriptionJob] = []
    @Published public private(set) var lastRefreshed: Date? = nil

    public let jobsDirectoryURL: URL
    private var timer: Timer?
    private var activeSubscribersCount: Int = 0
    private var reloadTask: Task<Void, Never>?

    public init(jobsDirectoryURL: URL = ResourceLocator.defaultJobsDirectoryURL) {
        self.jobsDirectoryURL = jobsDirectoryURL
        reloadJobs()
    }

    /// Schedules job file I/O and JSON decoding away from the UI actor.
    public func reloadJobs() {
        guard reloadTask == nil else { return }
        let directoryURL = jobsDirectoryURL

        reloadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) {
                Self.loadJobs(from: directoryURL)
            }.value
            guard let self else { return }
            self.reloadTask = nil
            guard !Task.isCancelled else { return }
            self.jobs = loaded
            self.lastRefreshed = Date()
        }
    }

    private nonisolated static func loadJobs(from jobsDirectoryURL: URL) -> [TranscriptionJob] {
        let fm = FileManager.default
        let path = jobsDirectoryURL.path

        guard fm.fileExists(atPath: path) else {
            return []
        }

        do {
            let files = try fm.contentsOfDirectory(at: jobsDirectoryURL, includingPropertiesForKeys: [.contentModificationDateKey])
            let jsonFiles = files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.contains(".tmp") }

            var loaded: [TranscriptionJob] = []
            let decoder = JSONDecoder()

            for file in jsonFiles {
                do {
                    let data = try Data(contentsOf: file)
                    let job = try decoder.decode(TranscriptionJob.self, from: data)
                    loaded.append(job)
                } catch {
                    // File may be partially written by server or corrupt; skip silently
                    continue
                }
            }

            loaded.sort { $0.updatedAt > $1.updatedAt }
            return loaded
        } catch {
            return []
        }
    }

    /// Starts polling timer when the UI is visible.
    public func startMonitoring() {
        activeSubscribersCount += 1
        if timer == nil {
            reloadJobs()
            timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reloadJobs()
                }
            }
        }
    }

    /// Stops polling timer when the UI is no longer visible.
    public func stopMonitoring() {
        activeSubscribersCount = max(0, activeSubscribersCount - 1)
        if activeSubscribersCount == 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Reveals the jobs directory in Finder.
    public func revealInFinder() {
        let fm = FileManager.default
        let path = jobsDirectoryURL.path
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(at: jobsDirectoryURL, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
        }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
}
