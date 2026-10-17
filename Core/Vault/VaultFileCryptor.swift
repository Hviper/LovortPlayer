import Foundation
import CryptoKit

/// Each authenticated chunk is bound to the file header, index and total size.
/// New files use bounded memory; the legacy single-GCM format remains readable.
public enum VaultFileCryptor {
    private static let magic = Data("LOVORTV2".utf8)
    private static let chunkSize = 4 * 1024 * 1024
    private static func integer<T: FixedWidthInteger>(_ value: T) -> Data { var value = value.bigEndian; return withUnsafeBytes(of: &value) { Data($0) } }
    private static func number(_ data: Data) -> UInt64 { data.reduce(0) { ($0 << 8) | UInt64($1) } }
    private static func read(_ handle: FileHandle, count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let part = try handle.read(upToCount: count - result.count), !part.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            result.append(part)
        }
        return result
    }
    public static func encrypt(source: URL, destination: URL, key: SymmetricKey, progress: (@Sendable (Double) -> Void)? = nil) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        try input.seek(toOffset: 0)
        var identifier = UUID().uuid
        let header = magic + withUnsafeBytes(of: &identifier) { Data($0) } + integer(size)
        try write(destination) { output in
            try output.write(contentsOf: header)
            var index: UInt64 = 0
            var consumed: UInt64 = 0
            repeat {
                try Task.checkCancellation()
                let count = Int(min(UInt64(chunkSize), size - consumed))
                try autoreleasepool {
                    let plain = count > 0 ? try read(input, count: count) : Data()
                    let sealedBox = try AES.GCM.seal(plain, using: key, authenticating: header + integer(index))
                    guard let sealed = sealedBox.combined else { throw CocoaError(.fileWriteUnknown) }
                    try output.write(contentsOf: integer(UInt32(sealed.count)))
                    try output.write(contentsOf: sealed)
                    consumed += UInt64(plain.count)
                    index += 1
                }
                if size > 0 {
                    progress?(min(1.0, Double(consumed) / Double(size)))
                }
            } while consumed < size
            guard (try input.read(upToCount: 1))?.isEmpty != false else { throw CocoaError(.fileReadCorruptFile) }
        }
        progress?(1.0)
    }
    public static func decrypt(source: URL, destination: URL, key: SymmetricKey, progress: (@Sendable (Double) -> Void)? = nil) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let prefix = try read(input, count: 8)
        if prefix != magic {
            // Compatibility with shipped single-GCM files; do not rewrite the source.
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
            try write(destination) { try $0.write(contentsOf: plain) }
            progress?(1.0)
            return
        }
        let header = prefix + (try read(input, count: 24))
        let size = number(header.suffix(8))
        try write(destination) { output in
            var consumed: UInt64 = 0
            var index: UInt64 = 0
            repeat {
                try Task.checkCancellation()
                try autoreleasepool {
                    let count = number(try read(input, count: 4))
                    guard count >= 28, count <= UInt64(chunkSize + 28) else { throw CocoaError(.fileReadCorruptFile) }
                    let sealed = try read(input, count: Int(count))
                    let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: header + integer(index))
                    guard plain.count == Int(min(UInt64(chunkSize), size - consumed)) else { throw CocoaError(.fileReadCorruptFile) }
                    try output.write(contentsOf: plain)
                    consumed += UInt64(plain.count)
                    index += 1
                }
                if size > 0 {
                    progress?(min(1.0, Double(consumed) / Double(size)))
                }
            } while consumed < size
            guard (try input.read(upToCount: 1))?.isEmpty != false else { throw CocoaError(.fileReadCorruptFile) }
        }
        progress?(1.0)
    }
    private static func write(_ destination: URL, operation: (FileHandle) throws -> Void) throws {
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".vault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stage) }
        guard FileManager.default.createFile(atPath: stage.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: stage.path)
        #endif
        let handle = try FileHandle(forWritingTo: stage)
        do { try operation(handle); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: stage, to: destination)
    }
}
