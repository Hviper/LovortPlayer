import Foundation

public final class MediaIdentityStore: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    public static let shared = MediaIdentityStore()
    public struct Record: Codable {
        public var id: UUID
        public var size: Int64
        public var modified: Date
        public var duration: Double
    }
    private var records: [String: Record] = [:]
    private let storeURL: URL
    private var saveTask: Task<Void, Never>?
    init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MediaIndex.json")
        if let data = try? Data(contentsOf: self.storeURL) { records = (try? JSONDecoder().decode([String: Record].self, from: data)) ?? [:] }
    }
    private func key(_ url: URL) -> String {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(documents) ? String(path.dropFirst(documents.count)) : path
    }
    public func id(for url: URL) -> UUID {
        lock.lock(); defer { lock.unlock() }
        if let record = records[key(url)] { return record.id }
        let id = UUID()
        records[key(url)] = Record(id: id, size: -1, modified: .distantPast, duration: 0)
        scheduleSave()
        return id
    }
    public func cachedDuration(for url: URL, size: Int64, modified: Date) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let record = records[key(url)], record.size == size, record.modified == modified else { return nil }
        return record.duration
    }
    public func update(_ url: URL, size: Int64, modified: Date, duration: Double) {
        lock.lock(); defer { lock.unlock() }
        records[key(url)] = Record(id: id(for: url), size: size, modified: modified, duration: duration)
        scheduleSave()
    }
    public func transfer(from source: URL, to destination: URL) {
        lock.lock(); defer { lock.unlock() }
        if let record = records.removeValue(forKey: key(source)) { records[key(destination)] = record }
        scheduleSave()
    }
    public func remove(_ url: URL) { lock.lock(); defer { lock.unlock() }; records[key(url)] = nil; scheduleSave() }
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task.detached { [self] in try? await Task.sleep(for: .milliseconds(500)); guard !Task.isCancelled else { return }; flush() }
    }
    public func flush() {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: storeURL.path)
        #endif
    }
}
