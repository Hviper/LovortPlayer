import XCTest
import Foundation
import CryptoKit
@testable import LovortPlayerCore

final class StorageReliabilityTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testDuplicateImportAndCopyFailurePreserveExistingVideo() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4"), old = root.appendingPathComponent("movie.mp4")
        try Data([1, 2]).write(to: source); try Data([9]).write(to: old)
        let destination = SafeFileImport.availableURL(name: "movie.mp4", in: root)
        XCTAssertNotEqual(destination, old)
        try SafeFileImport.copy(source, to: destination)
        XCTAssertEqual(try Data(contentsOf: old), Data([9]))
        XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2]))
        XCTAssertThrowsError(try SafeFileImport.copy(root.appendingPathComponent("missing.mp4"), to: old))
        XCTAssertEqual(try Data(contentsOf: old), Data([9]))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".import-") })
    }
    func testPrivateDuplicateRetainsPlayableExtensionAndPhotoStagingOwnership() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("movie.mp4.vault")
        try Data([1]).write(to: existing)
        XCTAssertEqual(SafeFileImport.availableURL(name: existing.lastPathComponent, in: root).lastPathComponent, "movie (2).mp4.vault")
        let source = root.appendingPathComponent("original.mp4")
        try Data([4, 5]).write(to: source)
        let staged = try PhotoImportStaging.copy(source)
        XCTAssertEqual(staged.lastPathComponent, source.lastPathComponent)
        PhotoImportStaging.release(source)
        XCTAssertEqual(try Data(contentsOf: source), Data([4, 5]))
        PhotoImportStaging.release(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }
    func testCancelledSubtitleRunCannotOverwriteNewCheckpoint() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let checkpoint = root.appendingPathComponent("checkpoint")
        let old = SubtitleRunPermit(), next = SubtitleRunPermit()
        try old.perform { try Data([1]).write(to: checkpoint, options: .atomic) }
        old.invalidate()
        try next.perform { try Data([2]).write(to: checkpoint, options: .atomic) }
        XCTAssertThrowsError(try old.perform { try Data([3]).write(to: checkpoint, options: .atomic) })
        XCTAssertEqual(try Data(contentsOf: checkpoint), Data([2]))
    }
    func testMediaIdentitySurvivesReloadAndMoveWithoutSameNameCollision() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("index.json")
        let first = root.appendingPathComponent("a/movie.mp4"), second = root.appendingPathComponent("b/movie.mp4")
        let store = MediaIdentityStore(storeURL: storeURL)
        let identity = store.id(for: first)
        XCTAssertNotEqual(identity, store.id(for: second))
        let date = Date(timeIntervalSince1970: 100)
        store.update(first, size: 10, modified: date, duration: 42)
        store.transfer(from: first, to: root.appendingPathComponent("movie.mp4.vault"))
        store.flush()
        let restored = MediaIdentityStore(storeURL: storeURL)
        let moved = root.appendingPathComponent("movie.mp4.vault")
        XCTAssertEqual(restored.id(for: moved), identity)
        XCTAssertEqual(restored.cachedDuration(for: moved, size: 10, modified: date), 42)
        XCTAssertNil(restored.cachedDuration(for: moved, size: 11, modified: date))
    }
    func testChunkEncryptionRoundTripEmptyAndMultipleChunks() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        for count in [0, 1024, 4 * 1024 * 1024 + 123] {
            let source = root.appendingPathComponent("source-\(count)"), encrypted = root.appendingPathComponent("enc-\(count)"), output = root.appendingPathComponent("out-\(count)")
            let data = Data(repeating: 0xAD, count: count)
            try data.write(to: source)
            try VaultFileCryptor.encrypt(source: source, destination: encrypted, key: key)
            try VaultFileCryptor.decrypt(source: encrypted, destination: output, key: key)
            XCTAssertEqual(try Data(contentsOf: output), data)
            XCTAssertEqual(try Data(contentsOf: source), data)
        }
    }
    func testVaultRejectsTamperingTruncationWrongKeyAndPreservesDestination() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let source = root.appendingPathComponent("source"), encrypted = root.appendingPathComponent("enc"), destination = root.appendingPathComponent("keep")
        try Data(repeating: 7, count: 500).write(to: source)
        try Data([9]).write(to: destination)
        try VaultFileCryptor.encrypt(source: source, destination: encrypted, key: key)
        XCTAssertThrowsError(try VaultFileCryptor.decrypt(source: encrypted, destination: destination, key: SymmetricKey(size: .bits256)))
        XCTAssertEqual(try Data(contentsOf: destination), Data([9]))
        var bytes = try Data(contentsOf: encrypted)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: encrypted)
        XCTAssertThrowsError(try VaultFileCryptor.decrypt(source: encrypted, destination: destination, key: key))
        try bytes.dropLast(12).write(to: encrypted)
        XCTAssertThrowsError(try VaultFileCryptor.decrypt(source: encrypted, destination: destination, key: key))
        XCTAssertEqual(try Data(contentsOf: destination), Data([9]))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".vault-") })
    }
    func testLegacyVaultFormatRemainsReadable() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256), plain = Data("旧版本内容".utf8)
        let source = root.appendingPathComponent("old.vault"), output = root.appendingPathComponent("movie.mp4")
        try AES.GCM.seal(plain, using: key).combined!.write(to: source)
        try VaultFileCryptor.decrypt(source: source, destination: output, key: key)
        XCTAssertEqual(try Data(contentsOf: output), plain)
    }
    func testPasswordBackupRoundTripAndWrongPasswordCannotOverwrite() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.zip")
        let encrypted = root.appendingPathComponent("library.lovortbackup")
        let output = root.appendingPathComponent("restored.zip")
        let data = Data(repeating: 0x5A, count: 4 * 1024 * 1024 + 19)
        try data.write(to: source)
        try BackupCryptor.encrypt(source: source, destination: encrypted, password: "test-password-123")
        XCTAssertThrowsError(try BackupCryptor.decrypt(source: encrypted, destination: output, password: "wrong-password"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try BackupCryptor.decrypt(source: encrypted, destination: output, password: "test-password-123")
        XCTAssertEqual(try Data(contentsOf: output), data)
    }
    func testASSDialogueParsingKeepsCommasAndStripsStyleOverrides() {
        let content = """
        [Script Info]
        Title: sample
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.20,0:00:03.40,Default,,0,0,0,,{\\i1}Hello, world\\N第二行
        """
        let lines = ASSParser.parse(content)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.startTime, 1.2)
        XCTAssertEqual(lines.first?.endTime, 3.4)
        XCTAssertEqual(lines.first?.originalText, "Hello, world\n第二行")
    }
    func testLANResumeKeepsPartialBytesAndFinalizesOnce() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let store = ResumableUploadStore(root: root.appendingPathComponent("Sessions"))
        let id = UUID()
        XCTAssertEqual(try store.status(id: id, name: "movie.mp4", size: 5).offset, 0)
        let partial = try store.beginChunk(id: id, offset: 0, length: 3)
        let first = try FileHandle(forWritingTo: partial)
        try first.write(contentsOf: Data("abc".utf8))
        try first.close()
        store.abortChunk(id: id)
        XCTAssertEqual(try store.status(id: id, name: "movie.mp4", size: 5).offset, 3)
        XCTAssertThrowsError(try store.beginChunk(id: id, offset: 0, length: 2))
        let resumed = try store.beginChunk(id: id, offset: 3, length: 2)
        let second = try FileHandle(forWritingTo: resumed)
        try second.seekToEnd()
        try second.write(contentsOf: Data("de".utf8))
        try second.close()
        let (state, saved) = try store.finishChunk(id: id, destinationDirectory: destination)
        XCTAssertTrue(state.complete)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(saved)), Data("abcde".utf8))
        XCTAssertTrue(try store.status(id: id, name: "movie.mp4", size: 5).complete)
    }
}
