import Foundation
import Network

public final class LANServerManager: @unchecked Sendable {
    public static let shared = LANServerManager()

    private var listener: NWListener?
    public private(set) var isRunning: Bool = false
    public private(set) var port: UInt16 = 8080

    public var onFileReceived: (@Sendable (URL, String) -> Void)?

    private init() {}

    public func startServer(port: UInt16 = 8080) throws {
        self.port = port
        let parameters = NWParameters.tcp
        let nwPort = NWEndpoint.Port(rawValue: port)!

        self.listener = try NWListener(using: parameters, on: nwPort)
        self.listener?.service = NWListener.Service(name: "LovortLANUpload", type: "_http._tcp")

        self.listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isRunning = true
            case .failed, .cancelled:
                self?.isRunning = false
            default:
                break
            }
        }

        self.listener?.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            self.handleConnection(connection)
        }

        self.listener?.start(queue: .main)
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        var buffer = Data()
        var expectedContentLength: Int?
        var fileName: String = "upload_\(Int(Date().timeIntervalSince1970)).mp4"
        var isHeaderParsed = false
        var tempFileURL: URL?
        var fileHandle: FileHandle?

        func receiveLoop() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1048576) { [weak self] data, _, isComplete, error in
                guard let self = self else {
                    connection.cancel()
                    return
                }

                if let data = data, !data.isEmpty {
                    if !isHeaderParsed {
                        buffer.append(data)
                        // 寻找 HTTP 头部结束标示 \r\n\r\n
                        let headerEndPattern = Data([0x0D, 0x0A, 0x0D, 0x0A])
                        if let range = buffer.range(of: headerEndPattern) {
                            let headerData = buffer.subdata(in: 0..<range.lowerBound)
                            let headerString = String(data: headerData, encoding: .utf8) ?? ""
                            let bodyData = buffer.subdata(in: range.upperBound..<buffer.count)
                            isHeaderParsed = true

                            if headerString.hasPrefix("GET ") {
                                let html = LANWebAssets.htmlUploadPage
                                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n"
                                let responseData = Data((header + html).utf8)
                                connection.send(content: responseData, completion: .contentProcessed({ _ in
                                    connection.cancel()
                                }))
                                return
                            } else if headerString.hasPrefix("POST /upload") {
                                // 解析文件名与 Content-Length
                                for line in headerString.components(separatedBy: "\r\n") {
                                    if line.lowercased().hasPrefix("x-file-name:") {
                                        let nameEncoded = line.dropFirst("x-file-name:".count).trimmingCharacters(in: .whitespaces)
                                        if let decoded = nameEncoded.removingPercentEncoding, !decoded.isEmpty {
                                            fileName = decoded
                                        }
                                    } else if line.lowercased().hasPrefix("content-length:") {
                                        let lenStr = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                                        expectedContentLength = Int(lenStr)
                                    }
                                }

                                // 创建临时文件写入
                                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + fileName)
                                FileManager.default.createFile(atPath: tempURL.path, contents: nil)
                                tempFileURL = tempURL
                                fileHandle = try? FileHandle(forWritingTo: tempURL)

                                if !bodyData.isEmpty {
                                    fileHandle?.write(bodyData)
                                }
                            } else {
                                let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                                connection.send(content: Data(response.utf8), completion: .contentProcessed({ _ in
                                    connection.cancel()
                                }))
                                return
                            }
                        }
                    } else {
                        // 已经解析完头部，继续将收到的数据流写入临时文件
                        fileHandle?.write(data)
                    }
                }

                if isComplete || error != nil {
                    // 上传完成或连接中断
                    fileHandle?.closeFile()
                    fileHandle = nil

                    if let tempURL = tempFileURL, FileManager.default.fileExists(atPath: tempURL.path) {
                        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        let targetURL = documents.appendingPathComponent(fileName)
                        try? FileManager.default.removeItem(at: targetURL)
                        try? FileManager.default.moveItem(at: tempURL, to: targetURL)

                        Task { @MainActor in
                            self.onFileReceived?(targetURL, fileName)
                            MediaLibraryManager.shared.reloadLibrary()
                        }
                    }

                    let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed({ _ in
                        connection.cancel()
                    }))
                } else {
                    receiveLoop()
                }
            }
        }

        receiveLoop()
    }

    public func stopServer() {
        self.listener?.cancel()
        self.listener = nil
        self.isRunning = false
    }

    /// 获取当前设备局域网 IP
    public func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" { // Wi-Fi interface
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
                }
            }
        }
        freeifaddrs(ifaddr)
        return address
    }
}
