import Combine
import Foundation
import Network

public final class LANServerManager: ObservableObject, @unchecked Sendable {
    public static let shared = LANServerManager()

    @Published public private(set) var isRunning = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var accessToken = ""
    public private(set) var port: UInt16 = 8080

    public var onFileReceived: (@Sendable (URL, String) -> Void)?

    private let serverQueue = DispatchQueue(label: "com.hviper.lovortplayer.lan-server", qos: .utility)
    private var listener: NWListener?

    private init() {}

    public func startServer(port: UInt16 = 8080) throws {
        guard listener == nil else { return }
        self.port = port
        accessToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(name: "LovortLANUpload", type: "_http._tcp")

        listener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    self.lastError = nil
                case .failed(let error):
                    self.isRunning = false
                    self.lastError = error.localizedDescription
                    self.listener?.cancel()
                    self.listener = nil
                case .cancelled:
                    self.isRunning = false
                    self.listener = nil
                default:
                    break
                }
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            LANUploadConnection(
                connection: connection,
                destinationDirectory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
                uploadPage: LANWebAssets.htmlUploadPage,
                accessToken: self.accessToken
            ) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let received):
                        self?.lastError = nil
                        self?.onFileReceived?(received.url, received.name)
                        MediaLibraryManager.shared.reloadLibrary()
                    case .failure(let error):
                        self?.lastError = error.localizedDescription
                    }
                }
            }.start(on: self.serverQueue)
        }

        self.listener = listener
        listener.start(queue: serverQueue)
    }

    public func stopServer() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async { [weak self] in
            self?.isRunning = false
        }
    }

    public func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for pointer in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: interface.ifa_name) == "en0" else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            address = String(cString: hostname)
            break
        }
        return address
    }
}

enum LANUploadPolicy {
    static let maximumHeaderBytes = 64 * 1_024
    static let maximumUploadBytes: Int64 = 50 * 1_024 * 1_024 * 1_024
    static let allowedExtensions = Set([
        "mp4", "mov", "m4v", "mkv", "avi", "webm", "flv", "wmv", "ts", "m2ts", "vob", "ogv", "3gp"
    ])

    static func sanitizedFileName(_ value: String) -> String {
        let name = URL(fileURLWithPath: value).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
        return name.components(separatedBy: invalid).joined(separator: "_")
    }
}

private struct ReceivedLANFile: Sendable {
    let url: URL
    let name: String
}

private final class LANUploadConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let destinationDirectory: URL
    private let uploadPage: String
    private let accessToken: String
    private let completion: @Sendable (Result<ReceivedLANFile, Error>) -> Void

    private var requestBuffer = Data()
    private var expectedBodyBytes: Int64?
    private var receivedBodyBytes: Int64 = 0
    private var requestedFileName: String?
    private var temporaryURL: URL?
    private var fileHandle: FileHandle?
    private var isFinished = false

    init(
        connection: NWConnection,
        destinationDirectory: URL,
        uploadPage: String,
        accessToken: String,
        completion: @escaping @Sendable (Result<ReceivedLANFile, Error>) -> Void
    ) {
        self.connection = connection
        self.destinationDirectory = destinationDirectory
        self.uploadPage = uploadPage
        self.accessToken = accessToken
        self.completion = completion
    }

    func start(on queue: DispatchQueue) {
        connection.start(queue: queue)
        receiveNext()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty { consume(data) }
            guard !isFinished else { return }
            if let error {
                fail(status: "500 Internal Server Error", message: error.localizedDescription)
            } else if isComplete {
                fail(status: "400 Bad Request", message: "上传连接提前中断")
            } else {
                receiveNext()
            }
        }
    }

    private func consume(_ data: Data) {
        if expectedBodyBytes == nil {
            requestBuffer.append(data)
            let separator = Data([13, 10, 13, 10])
            guard let headerRange = requestBuffer.range(of: separator) else {
                if requestBuffer.count > LANUploadPolicy.maximumHeaderBytes {
                    fail(status: "431 Request Header Fields Too Large", message: "请求头过大")
                }
                return
            }
            guard headerRange.lowerBound <= LANUploadPolicy.maximumHeaderBytes else {
                fail(status: "431 Request Header Fields Too Large", message: "请求头过大")
                return
            }
            let headerData = requestBuffer[..<headerRange.lowerBound]
            let bodyData = Data(requestBuffer[headerRange.upperBound...])
            requestBuffer.removeAll(keepingCapacity: false)
            handleHeader(String(decoding: headerData, as: UTF8.self), initialBody: bodyData)
        } else {
            writeBody(data)
        }
    }

    private func handleHeader(_ header: String, initialBody: Data) {
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            fail(status: "400 Bad Request", message: "无效请求")
            return
        }
        if requestLine.hasPrefix("GET /?token=\(accessToken) ") {
            let page = uploadPage.replacingOccurrences(of: "{{UPLOAD_TOKEN}}", with: accessToken)
            send(status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(page.utf8))
            return
        }
        guard requestLine.hasPrefix("POST /upload ") else {
            fail(status: "404 Not Found", message: "路径不存在")
            return
        }

        var contentLength: Int64?
        var encodedName: String?
        var requestToken: String?
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "content-length": contentLength = Int64(parts[1].trimmingCharacters(in: .whitespaces))
            case "x-file-name": encodedName = parts[1].trimmingCharacters(in: .whitespaces)
            case "x-upload-token": requestToken = parts[1].trimmingCharacters(in: .whitespaces)
            default: break
            }
        }
        guard requestToken == accessToken else {
            fail(status: "403 Forbidden", message: "上传口令无效，请重新打开手机显示的网址")
            return
        }
        guard let contentLength, contentLength > 0, contentLength <= LANUploadPolicy.maximumUploadBytes else {
            fail(status: "413 Payload Too Large", message: "文件大小无效或超过 50 GB")
            return
        }
        let decodedName = encodedName?.removingPercentEncoding ?? encodedName ?? ""
        let safeName = LANUploadPolicy.sanitizedFileName(decodedName)
        guard !safeName.isEmpty, LANUploadPolicy.allowedExtensions.contains(URL(fileURLWithPath: safeName).pathExtension.lowercased()) else {
            fail(status: "415 Unsupported Media Type", message: "不支持该文件格式")
            return
        }
        guard hasAvailableCapacity(for: contentLength) else {
            fail(status: "507 Insufficient Storage", message: "设备可用空间不足")
            return
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("lovort-upload-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: tempURL) else {
            fail(status: "500 Internal Server Error", message: "无法创建上传文件")
            return
        }
        expectedBodyBytes = contentLength
        requestedFileName = safeName
        temporaryURL = tempURL
        fileHandle = handle
        writeBody(initialBody)
    }

    private func writeBody(_ data: Data) {
        guard let expectedBodyBytes, !isFinished else { return }
        let remaining = expectedBodyBytes - receivedBodyBytes
        guard remaining > 0 else {
            finishUpload()
            return
        }
        let writeCount = min(Int64(data.count), remaining)
        if writeCount > 0 {
            do {
                try fileHandle?.write(contentsOf: data.prefix(Int(writeCount)))
                receivedBodyBytes += writeCount
            } catch {
                fail(status: "500 Internal Server Error", message: "写入文件失败")
                return
            }
        }
        if receivedBodyBytes == expectedBodyBytes { finishUpload() }
    }

    private func finishUpload() {
        guard !isFinished, let temporaryURL, let requestedFileName else { return }
        isFinished = true
        try? fileHandle?.close()
        fileHandle = nil
        do {
            let destination = uniqueDestination(for: requestedFileName)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            completion(.success(ReceivedLANFile(url: destination, name: destination.lastPathComponent)))
            send(status: "200 OK", contentType: "text/plain; charset=utf-8", body: Data("OK".utf8), markFinished: false)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            completion(.failure(error))
            send(status: "500 Internal Server Error", contentType: "text/plain; charset=utf-8", body: Data("保存失败".utf8), markFinished: false)
        }
    }

    private func fail(status: String, message: String) {
        guard !isFinished else { return }
        isFinished = true
        try? fileHandle?.close()
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        completion(.failure(NSError(domain: "LANUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: message])))
        send(status: status, contentType: "text/plain; charset=utf-8", body: Data(message.utf8), markFinished: false)
    }

    private func send(status: String, contentType: String, body: Data, markFinished: Bool = true) {
        if markFinished { isFinished = true }
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }

    private func uniqueDestination(for name: String) -> URL {
        let source = URL(fileURLWithPath: name)
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = destinationDirectory.appendingPathComponent(name)
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = destinationDirectory.appendingPathComponent("\(stem) (\(suffix)).\(ext)")
            suffix += 1
        }
        return candidate
    }

    private func hasAvailableCapacity(for bytes: Int64) -> Bool {
        guard let values = try? destinationDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else { return true }
        return capacity > bytes + 256 * 1_024 * 1_024
    }
}
