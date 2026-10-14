import Foundation

/// Invalidating a run waits for its current atomic checkpoint and rejects every later write.
public final class SubtitleRunPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    public init() {}
    public func invalidate() {
        lock.lock()
        valid = false
        lock.unlock()
    }
    public func perform<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard valid else { throw CancellationError() }
        return try operation()
    }
}
