import Foundation
import Combine
import Darwin

@MainActor
public final class ServiceProcessManager: ObservableObject {
    public static let shared = ServiceProcessManager()

    @Published public private(set) var status: ServiceStatus = .stopped
    @Published public private(set) var statusDetail: String = ""
    @Published public private(set) var environmentReport: EnvironmentReport? = nil
    @Published public private(set) var isExternallyManaged: Bool = false

    private var activeProcess: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var readinessTask: Task<Void, Never>?
    private var stateRefreshTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?

    public init() {}

    /// Checks a compatible service first, then evaluates the local environment off the main actor.
    public func refreshState(host: String, port: Int, tokenManager: TokenManager) {
        if let process = activeProcess, process.isRunning {
            status = .running
            statusDetail = "服务正在本机后台运行"
            isExternallyManaged = false
            return
        }

        stateRefreshTask?.cancel()
        tokenManager.reloadToken()
        let token = tokenManager.token
        let probeHost = Self.healthProbeHost(for: host)
        let venvURL = ResourceLocator.resolveActiveVenvURL()

        stateRefreshTask = Task { [weak self] in
            guard let self else { return }

            if await Self.probeHealth(host: probeHost, port: port, token: token) {
                guard !Task.isCancelled else { return }
                self.isExternallyManaged = true
                self.status = .running
                self.statusDetail = "检测到终端或其他进程启动的兼容服务"
                return
            }

            let report = await Task.detached(priority: .userInitiated) {
                EnvironmentChecker.shared.checkEnvironment(venvURL: venvURL)
            }.value
            guard !Task.isCancelled else { return }
            self.applyEnvironmentReport(report)
        }
    }

    /// Launches the Python service after an asynchronous preflight and compatibility probe.
    public func startService(
        host: String,
        port: Int,
        logStore: LogStore,
        tokenManager: TokenManager
    ) {
        guard status != .starting && activeProcess?.isRunning != true else { return }

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...65535).contains(port), Self.isAllowedHost(trimmedHost) else {
            status = .error
            statusDetail = "监听地址或端口无效；请使用 0.0.0.0、127.0.0.1 或本机局域网地址，以及 1-65535 端口"
            logStore.append(rawLine: "[错误] 无效的监听配置: \(trimmedHost):\(port)", isError: true)
            return
        }

        status = .starting
        statusDetail = "正在检查服务与运行环境..."
        isExternallyManaged = false
        startTask?.cancel()
        stateRefreshTask?.cancel()
        tokenManager.reloadToken()

        let token = tokenManager.token
        let probeHost = Self.healthProbeHost(for: trimmedHost)
        let venvURL = ResourceLocator.resolveActiveVenvURL()

        startTask = Task { [weak self] in
            guard let self else { return }

            if await Self.probeHealth(host: probeHost, port: port, token: token) {
                guard !Task.isCancelled else { return }
                self.isExternallyManaged = true
                self.status = .running
                self.statusDetail = "检测到终端或其他进程启动的兼容服务"
                logStore.append(rawLine: "==> 已连接端口 \(port) 上正在运行的兼容字幕服务")
                return
            }

            let report = await Task.detached(priority: .userInitiated) {
                EnvironmentChecker.shared.checkEnvironment(venvURL: venvURL)
            }.value
            guard !Task.isCancelled else { return }
            self.environmentReport = report

            guard report.isFullyReady else {
                self.applyEnvironmentReport(report)
                logStore.append(rawLine: "[提示] 启动前请先完成环境配置", isError: true)
                return
            }

            self.launchService(
                host: trimmedHost,
                port: port,
                report: report,
                venvURL: venvURL,
                probeHost: probeHost,
                logStore: logStore,
                tokenManager: tokenManager
            )
        }
    }

    private func launchService(
        host: String,
        port: Int,
        report: EnvironmentReport,
        venvURL: URL,
        probeHost: String,
        logStore: LogStore,
        tokenManager: TokenManager
    ) {
        guard status == .starting else { return }
        guard let serverPy = ResourceLocator.resolveServerPy() else {
            status = .error
            statusDetail = "未找到 server.py 脚本文件"
            logStore.append(rawLine: "[错误] 未找到 server.py 服务脚本", isError: true)
            return
        }

        let pythonBinURL = venvURL.appendingPathComponent("bin/python")
        guard FileManager.default.isExecutableFile(atPath: pythonBinURL.path) else {
            status = .uninstalled
            statusDetail = "未找到虚拟环境 Python: \(pythonBinURL.path)"
            logStore.append(rawLine: "[错误] 虚拟环境 Python 可执行文件丢失", isError: true)
            return
        }

        let tokenFile = ResourceLocator.defaultTokenFileURL
        let jobsDir = ResourceLocator.defaultJobsDirectoryURL
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: tokenFile.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.createDirectory(
                at: jobsDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            status = .error
            statusDetail = "无法创建运行目录: \(error.localizedDescription)"
            logStore.append(rawLine: "[错误] \(statusDetail)", isError: true)
            return
        }

        statusDetail = "正在启动服务进程..."
        logStore.append(rawLine: "==> 正在启动字幕服务 (端口 \(port))...")

        let process = Process()
        process.executableURL = pythonBinURL
        process.arguments = [
            "-u", serverPy.path,
            "--host", host,
            "--port", String(port),
            "--token-file", tokenFile.path,
            "--jobs-dir", jobsDir.path
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        if let ffmpegPath = report.ffmpegPath { environment["LOVORT_FFMPEG"] = ffmpegPath }
        if let ffprobePath = report.ffprobePath { environment["LOVORT_FFPROBE"] = ffprobePath }
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                logStore.append(rawLine: text)
                if text.contains("listening on") {
                    tokenManager.reloadToken()
                }
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                logStore.append(rawLine: text, isError: true)
            }
        }

        stdoutPipe = outPipe
        stderrPipe = errPipe
        activeProcess = process

        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
                self.stderrPipe?.fileHandleForReading.readabilityHandler = nil
                self.activeProcess = nil
                self.readinessTask?.cancel()
                self.isExternallyManaged = false

                let code = process.terminationStatus
                if self.status == .error {
                    logStore.append(rawLine: "==> 服务进程已退出 (退出码 \(code))", isError: true)
                } else if code == 0 || code == SIGTERM {
                    self.status = .stopped
                    self.statusDetail = "服务已停止"
                    logStore.append(rawLine: "==> 服务已停止 (退出码 \(code))")
                } else {
                    self.status = .error
                    self.statusDetail = "服务异常退出 (退出码 \(code))"
                    logStore.append(rawLine: "[错误] 服务异常退出，退出码: \(code)", isError: true)
                }
            }
        }

        do {
            try process.run()
            readinessTask = Task { [weak self] in
                guard let self else { return }
                for _ in 0..<60 {
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .milliseconds(500))
                    guard self.activeProcess?.isRunning == true else { return }
                    tokenManager.reloadToken()
                    let currentToken = tokenManager.token
                    if await Self.probeHealth(host: probeHost, port: port, token: currentToken) {
                        guard !Task.isCancelled else { return }
                        self.status = .running
                        self.statusDetail = "服务运行中，端口 \(port)"
                        self.isExternallyManaged = false
                        return
                    }
                }

                guard self.activeProcess?.isRunning == true else { return }
                self.status = .error
                self.statusDetail = "服务启动超时，健康检查未通过"
                logStore.append(rawLine: "[错误] 服务进程已启动，但 30 秒内未通过 /health 检查", isError: true)
                self.activeProcess?.terminate()
            }
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            activeProcess = nil
            status = .error
            statusDetail = "启动进程失败: \(error.localizedDescription)"
            logStore.append(rawLine: "[错误] 启动进程失败: \(error.localizedDescription)", isError: true)
        }
    }

    /// Stops only a service process launched by this GUI.
    public func stopService(logStore: LogStore) {
        guard let process = activeProcess, process.isRunning else {
            if isExternallyManaged {
                statusDetail = "该服务由终端或其他进程管理，请在原启动位置停止"
            } else {
                status = .stopped
                statusDetail = "服务未运行"
            }
            return
        }

        readinessTask?.cancel()
        logStore.append(rawLine: "==> 正在发送停止信号 (SIGTERM)...")
        process.terminate()

        Task {
            for _ in 0..<15 {
                if !process.isRunning { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
            if process.isRunning {
                logStore.append(rawLine: "==> 进程未响应，正在强制终止 (SIGKILL)...", isError: true)
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    public func terminateOnAppQuit() {
        if let process = activeProcess, process.isRunning {
            process.terminate()
        }
    }

    private func applyEnvironmentReport(_ report: EnvironmentReport) {
        environmentReport = report
        isExternallyManaged = false

        if report.isFullyReady {
            status = .stopped
            statusDetail = "环境已就绪，服务未运行"
        } else {
            status = .uninstalled
            if !report.isHardwareReady {
                statusDetail = "硬件不支持: MLX Whisper 需 Apple Silicon (M 系列芯片)"
            } else if !report.hasRequiredSystemTools {
                statusDetail = "缺少系统工具: " + report.missingPrerequisites.joined(separator: "; ")
            } else {
                statusDetail = "环境未就绪: Python 虚拟环境或 mlx-whisper 尚未安装"
            }
        }
    }

    private nonisolated static func healthProbeHost(for host: String) -> String {
        host == "0.0.0.0" ? "127.0.0.1" : host
    }

    private nonisolated static func probeHealth(host: String, port: Int, token: String) async -> Bool {
        guard !token.isEmpty, (1...65535).contains(port) else { return false }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = "/health"
        guard let url = components.url else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.setValue(token, forHTTPHeaderField: "X-Lovort-Token")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return payload["service"] as? String == "lovort-mac-subtitles"
        } catch {
            return false
        }
    }

    private nonisolated static func isAllowedHost(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        if host == "0.0.0.0" || host == "127.0.0.1" { return true }
        return NetworkManager.getLocalIPAddresses().contains(host)
    }
}
