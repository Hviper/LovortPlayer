import Foundation
#if canImport(Darwin)
import Darwin
#endif

public actor SubtitlePerformanceLog {
    public static let shared = SubtitlePerformanceLog()
    public struct Entry: Codable, Identifiable, Sendable {
        public let id: UUID
        public let date: Date
        public let stage: String
        public let model: String
        public let seconds: Double
        public let workers: Int
        public let backend: String
        public let thermal: String
        public let residentBytes: UInt64
    }
    private var entries: [Entry] = []
    private let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SubtitlePerformance.json")
    private init() { if let data = try? Data(contentsOf: url) { entries = (try? JSONDecoder().decode([Entry].self, from: data)) ?? [] } }
    public func record(stage: String, model: String, seconds: Double, workers: Int = 0, backend: String = "") {
        var memory: UInt64 = 0
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        if status == KERN_SUCCESS { memory = info.resident_size }
        #endif
        entries.append(Entry(id: UUID(), date: Date(), stage: stage, model: model, seconds: seconds,
                             workers: workers, backend: backend, thermal: String(describing: ProcessInfo.processInfo.thermalState), residentBytes: memory))
        if entries.count > 100 { entries.removeFirst(entries.count - 100) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: url, options: .atomic) }
    }
    public func snapshot() -> [Entry] { entries.reversed() }
    public func clear() { entries.removeAll(); try? FileManager.default.removeItem(at: url) }
}
