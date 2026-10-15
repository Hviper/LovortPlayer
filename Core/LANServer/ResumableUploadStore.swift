import Foundation

struct LANUploadStatus: Codable {
    let offset: Int64
    let complete: Bool
    let savedName: String?
}

/// Serializes claims on each partial upload and keeps progress across page reloads.
final class ResumableUploadStore: @unchecked Sendable {
    static let shared = ResumableUploadStore()
    private let lock = NSLock()
    private var active: Set<UUID> = []
    private let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("LovortUploadSessions", isDirectory: true)
    }

    func status(id: UUID, name: String, size: Int64) throws -> LANUploadStatus {
        lock.lock(); defer { lock.unlock() }
        try prepareDirectory()
        if let done = try? loadDone(id: id) {
            guard done.name == name, done.size == size else { throw failure("上传 ID 对应的文件不一致") }
            return LANUploadStatus(offset: size, complete: true, savedName: done.savedName)
        }
        let metadata: Metadata
        if let existing = try? load(id: id) {
            guard existing.name == name, existing.size == size else { throw failure("上传 ID 对应的文件不一致") }
            metadata = existing
        } else {
            guard size > 0, size <= LANUploadPolicy.maximumUploadBytes else { throw failure("文件大小无效") }
            metadata = Metadata(name: name, size: size, updatedAt: Date())
            try JSONEncoder().encode(metadata).write(to: metaURL(id), options: .atomic)
            guard FileManager.default.createFile(atPath: partURL(id).path, contents: nil) else { throw failure("无法创建上传文件") }
            #if os(iOS)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: partURL(id).path)
            #endif
        }
        let offset = try fileSize(partURL(id))
        guard offset <= metadata.size else { throw failure("上传进度已损坏") }
        return LANUploadStatus(offset: offset, complete: false, savedName: nil)
    }

    func beginChunk(id: UUID, offset: Int64, length: Int64) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let metadata = try load(id: id)
        guard !active.contains(id) else { throw failure("该文件已有上传分片在进行") }
        guard length > 0, length <= 4 * 1024 * 1024,
              offset == (try fileSize(partURL(id))),
              offset >= 0, offset + length <= metadata.size else { throw failure("分片位置不匹配，请刷新进度后重试") }
        active.insert(id)
        return partURL(id)
    }

    func finishChunk(id: UUID, destinationDirectory: URL) throws -> (LANUploadStatus, URL?) {
        lock.lock(); defer { lock.unlock() }
        defer { active.remove(id) }
        let metadata = try load(id: id)
        let offset = try fileSize(partURL(id))
        guard offset <= metadata.size else { throw failure("上传大小超出预期") }
        guard offset == metadata.size else { return (LANUploadStatus(offset: offset, complete: false, savedName: nil), nil) }
        let destination = SafeFileImport.availableURL(name: metadata.name, in: destinationDirectory)
        try FileManager.default.moveItem(at: partURL(id), to: destination)
        let done = Completed(name: metadata.name, size: metadata.size, savedName: destination.lastPathComponent, updatedAt: Date())
        try? JSONEncoder().encode(done).write(to: doneURL(id), options: .atomic)
        try? FileManager.default.removeItem(at: metaURL(id))
        return (LANUploadStatus(offset: metadata.size, complete: true, savedName: destination.lastPathComponent), destination)
    }

    func abortChunk(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        active.remove(id)
    }

    func cleanupExpired() {
        lock.lock(); defer { lock.unlock() }
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for file in files {
            let idText = file.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: idText), !active.contains(id) else { continue }
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               date < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    private struct Metadata: Codable { let name: String; let size: Int64; let updatedAt: Date }
    private struct Completed: Codable { let name: String; let size: Int64; let savedName: String; let updatedAt: Date }
    private func metaURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".json") }
    private func doneURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".done") }
    private func partURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".part") }
    private func load(id: UUID) throws -> Metadata { try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: metaURL(id))) }
    private func loadDone(id: UUID) throws -> Completed { try JSONDecoder().decode(Completed.self, from: Data(contentsOf: doneURL(id))) }
    private func fileSize(_ url: URL) throws -> Int64 { Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: root.path)
        #endif
    }
    private func failure(_ text: String) -> NSError {
        NSError(domain: "LANResume", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
