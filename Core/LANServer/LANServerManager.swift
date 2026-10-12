import Foundation
import Network

public final class LANServerManager: @unchecked Sendable {
    public static let shared = LANServerManager()

    private var listener: NWListener?
    public private(set) var isRunning: Bool = false
    public private(set) var port: UInt16 = 8080

    private init() {}

    public var onFileReceived: (@Sendable (URL, String) -> Void)?

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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self = self, let data = data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            if request.hasPrefix("GET / ") {
                let html = LANWebAssets.htmlUploadPage
                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n"
                let responseData = Data((header + html).utf8)
                connection.send(content: responseData, completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
            } else if request.hasPrefix("POST /upload") {
                // 回复 200 OK 确认接收
                let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"
                connection.send(content: Data(response.utf8), completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
            } else {
                let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
            }
        }
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
