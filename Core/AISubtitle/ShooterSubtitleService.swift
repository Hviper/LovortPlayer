import Foundation
import CryptoKit

public struct CommunitySubtitleResult: Identifiable, Sendable {
    public let id = UUID()
    public let desc: String
    public let delay: Int
    public let fileExt: String
    public let downloadURL: URL
}

/// 射手网 (Shooter.cn / Assrt) 开放字幕协议客户端
/// 通过视频特征哈希极速检索开源社区/动漫字幕组精校双语字幕
public final class ShooterSubtitleService: Sendable {
    public static let shared = ShooterSubtitleService()

    private init() {}

    /// 计算射手网专用的视频文件指纹哈希
    public func computeShooterHash(for fileURL: URL) -> String? {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? fileHandle.close() }

        guard let fileSize = try? fileHandle.seekToEnd(), fileSize >= 16384 else { return nil }

        let blockOffsets: [UInt64] = [
            4096,
            fileSize / 3,
            fileSize / 3 * 2,
            fileSize - 8192
        ]

        var hashes: [String] = []

        for offset in blockOffsets {
            do {
                try fileHandle.seek(toOffset: offset)
                let blockData = fileHandle.readData(ofLength: 4096)
                if blockData.count == 4096 {
                    let digest = Insecure.MD5.hash(data: blockData)
                    let hashStr = digest.map { String(format: "%02x", $0) }.joined()
                    hashes.append(hashStr)
                }
            } catch {
                return nil
            }
        }

        guard hashes.count == 4 else { return nil }
        return hashes.joined(separator: ";")
    }

    /// 向社区字幕库检索匹配的精校字幕
    public func fetchCommunitySubtitles(videoURL: URL) async throws -> [CommunitySubtitleResult] {
        guard let hash = computeShooterHash(for: videoURL) else { return [] }

        guard let apiURL = URL(string: "https://www.shooter.cn/api/subapi.php") else { return [] }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendFormField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendFormField(name: "filehash", value: hash)
        appendFormField(name: "pathinfo", value: videoURL.lastPathComponent)
        appendFormField(name: "format", value: "json")
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
            return []
        }

        guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        var results: [CommunitySubtitleResult] = []

        for item in jsonArray {
            let desc = item["Desc"] as? String ?? "社区字幕组精校"
            let delay = item["Delay"] as? Int ?? 0
            if let files = item["Files"] as? [[String: Any]] {
                for f in files {
                    if let ext = f["Ext"] as? String,
                       let link = f["Link"] as? String,
                       let url = URL(string: link) {
                        results.append(
                            CommunitySubtitleResult(
                                desc: desc,
                                delay: delay,
                                fileExt: ext.lowercased(),
                                downloadURL: url
                            )
                        )
                    }
                }
            }
        }

        return results
    }

    /// 下载并解析社区字幕为标准 SubtitleLine 列表
    public func downloadAndParseSubtitle(from url: URL) async throws -> [SubtitleLine] {
        let (data, _) = try await URLSession.shared.data(from: url)
        // 尝试 UTF-8 或 GB18030 / Shift-JIS 编码解码
        let content: String
        if let s = String(data: data, encoding: .utf8) {
            content = s
        } else if let cfEncoding = CFStringConvertNSStringEncodingToEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)) as NSStringEncoding?,
                  let s = String(data: data, encoding: String.Encoding(rawValue: cfEncoding)) {
            content = s
        } else {
            content = String(decoding: data, as: UTF8.self)
        }

        return SRTParser.parse(srtString: content)
    }
}
