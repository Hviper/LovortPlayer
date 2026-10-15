import Foundation
import CryptoKit
import CommonCrypto
import Security

/// Password-encrypted, authenticated, bounded-memory backup container.
public enum BackupCryptor {
    private static let magic = Data("LOVORTBACKUPV1".utf8)
    private static let chunkSize = 4 * 1024 * 1024

    public static func encrypt(source: URL, destination: URL, password: String) throws {
        guard password.utf8.count >= 8 else { throw failure("备份密码至少需要 8 个字符") }
        var salt = Data(count: 16)
        guard salt.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }) == errSecSuccess else {
            throw failure("无法生成备份加密盐")
        }
        let size = UInt64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let header = magic + salt + bytes(size)
        let key = derive(password, salt: salt)
        try write(destination) { output in
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            try output.write(contentsOf: header)
            var consumed: UInt64 = 0
            var index: UInt64 = 0
            repeat {
                try Task.checkCancellation()
                let plain = try exact(input, count: Int(min(UInt64(chunkSize), size - consumed)))
                let sealed = try AES.GCM.seal(plain, using: key, authenticating: header + bytes(index)).combined!
                try output.write(contentsOf: bytes(UInt32(sealed.count)) + sealed)
                consumed += UInt64(plain.count)
                index += 1
            } while consumed < size
            guard (try input.read(upToCount: 1))?.isEmpty != false else { throw failure("源文件在备份时发生变化") }
        }
    }

    public static func decrypt(source: URL, destination: URL, password: String) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let prefix = try exact(input, count: magic.count)
        guard prefix == magic else { throw failure("不是 LovortPlayer 备份文件") }
        let salt = try exact(input, count: 16)
        let sizeData = try exact(input, count: 8)
        let size = number(sizeData)
        let header = prefix + salt + sizeData
        let key = derive(password, salt: salt)
        try write(destination) { output in
            var consumed: UInt64 = 0
            var index: UInt64 = 0
            repeat {
                try Task.checkCancellation()
                let sealedSize = number(try exact(input, count: 4))
                guard sealedSize >= 28, sealedSize <= UInt64(chunkSize + 28) else { throw failure("备份文件已损坏") }
                let sealed = try exact(input, count: Int(sealedSize))
                let plain: Data
                do {
                    plain = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key,
                                             authenticating: header + bytes(index))
                } catch { throw failure("备份密码错误或文件已损坏") }
                guard plain.count == Int(min(UInt64(chunkSize), size - consumed)) else { throw failure("备份文件已损坏") }
                try output.write(contentsOf: plain)
                consumed += UInt64(plain.count)
                index += 1
            } while consumed < size
            guard (try input.read(upToCount: 1))?.isEmpty != false else { throw failure("备份文件包含多余数据") }
        }
    }

    private static func derive(_ password: String, salt: Data) -> SymmetricKey {
        var output = Data(count: 32)
        let pass = Array(password.utf8)
        _ = pass.withUnsafeBytes { passBytes in
            salt.withUnsafeBytes { saltBytes in
                output.withUnsafeMutableBytes { outBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        passBytes.baseAddress!.assumingMemoryBound(to: Int8.self), pass.count,
                        saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000,
                        outBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        return SymmetricKey(data: output)
    }

    private static func exact(_ input: FileHandle, count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try input.read(upToCount: count - data.count), !chunk.isEmpty else { throw failure("备份文件不完整") }
            data.append(chunk)
        }
        return data
    }
    private static func bytes<T: FixedWidthInteger>(_ value: T) -> Data {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
    }
    private static func number(_ data: Data) -> UInt64 { data.reduce(0) { ($0 << 8) | UInt64($1) } }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "LovortBackup", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static func write(_ destination: URL, operation: (FileHandle) throws -> Void) throws {
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stage) }
        guard FileManager.default.createFile(atPath: stage.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: stage.path)
        #endif
        let output = try FileHandle(forWritingTo: stage)
        do { try operation(output); try output.synchronize(); try output.close() }
        catch { try? output.close(); throw error }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: stage, to: destination)
    }
}
