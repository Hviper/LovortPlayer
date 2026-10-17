import Foundation
import Combine

@MainActor
public final class EnvironmentInstaller: ObservableObject {
    public static let shared = EnvironmentInstaller()

    @Published public private(set) var isInstalling: Bool = false
    @Published public private(set) var currentStage: String = ""
    @Published public private(set) var errorMessage: String? = nil

    private var activeProcess: Process?
    private var cancelRequested = false

    public init() {}

    /// Runs a process with streaming stdout and stderr to the log store using array arguments only.
    private func runSubprocess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        stageDescription: String,
        logStore: LogStore
    ) async throws {
        self.currentStage = stageDescription
        logStore.append(rawLine: "==> [安装环境] \(stageDescription)")
        logStore.append(rawLine: "$ \(executableURL.lastPathComponent) \(arguments.joined(separator: " "))")

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        if let customEnv = environment {
            for (key, val) in customEnv { env[key] = val }
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                logStore.append(rawLine: text)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                logStore.append(rawLine: text)
            }
        }

        self.activeProcess = process

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { [weak self] proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                Task { @MainActor in
                    guard let self else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if self.activeProcess === proc {
                        self.activeProcess = nil
                    }

                    if self.cancelRequested {
                        continuation.resume(throwing: CancellationError())
                    } else if proc.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let error = NSError(
                            domain: "LovortEnvironmentInstaller",
                            code: Int(proc.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: "\(stageDescription) 失败，退出码: \(proc.terminationStatus)"]
                        )
                        continuation.resume(throwing: error)
                    }
                }
            }

            do {
                try process.run()
            } catch {
                self.activeProcess = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// Performs one-click installation of virtual environment and requirements.
    public func installEnvironment(
        pythonPath: String,
        venvURL: URL,
        requirementsURL: URL,
        logStore: LogStore
    ) async -> Bool {
        guard !isInstalling else { return false }
        isInstalling = true
        cancelRequested = false
        errorMessage = nil

        defer {
            isInstalling = false
            currentStage = ""
            activeProcess = nil
            cancelRequested = false
        }

        let fm = FileManager.default

        // Step 1: Ensure parent folder exists
        let parentDir = venvURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        } catch {
            errorMessage = "创建应用支持目录失败: \(error.localizedDescription)"
            logStore.append(rawLine: "[错误] \(errorMessage!)", isError: true)
            return false
        }

        // Step 2: Create virtual environment
        do {
            try await runSubprocess(
                executableURL: URL(fileURLWithPath: pythonPath),
                arguments: ["-m", "venv", venvURL.path],
                stageDescription: "创建 Python 虚拟环境",
                logStore: logStore
            )
        } catch is CancellationError {
            logStore.append(rawLine: "==> [安装环境] 已取消")
            return false
        } catch {
            errorMessage = "虚拟环境创建失败: \(error.localizedDescription)"
            logStore.append(rawLine: "[错误] \(errorMessage!)", isError: true)
            return false
        }

        guard !cancelRequested else {
            logStore.append(rawLine: "==> [安装环境] 已取消")
            return false
        }

        // Step 3: Install requirements via pip
        let pipURL = venvURL.appendingPathComponent("bin/pip")
        guard fm.isExecutableFile(atPath: pipURL.path) else {
            errorMessage = "未在虚拟环境中找到 pip 可执行文件: \(pipURL.path)"
            logStore.append(rawLine: "[错误] \(errorMessage!)", isError: true)
            return false
        }

        do {
            try await runSubprocess(
                executableURL: pipURL,
                arguments: ["install", "-r", requirementsURL.path],
                stageDescription: "安装依赖 (mlx-whisper 等)",
                logStore: logStore
            )
        } catch is CancellationError {
            logStore.append(rawLine: "==> [安装环境] 已取消")
            return false
        } catch {
            errorMessage = "安装依赖失败: \(error.localizedDescription)"
            logStore.append(rawLine: "[错误] \(errorMessage!)", isError: true)
            return false
        }

        // Step 4: Verify
        let check = EnvironmentChecker.checkVenv(at: venvURL)
        if check.hasMlxWhisper {
            logStore.append(rawLine: "==> [安装环境] 虚拟环境与依赖配置完成！")
            return true
        } else {
            errorMessage = "虚拟环境安装后未能验证 mlx_whisper 模块"
            logStore.append(rawLine: "[错误] \(errorMessage!)", isError: true)
            return false
        }
    }

    /// Cancels any running install process.
    public func cancel() {
        guard isInstalling, !cancelRequested else { return }
        cancelRequested = true
        currentStage = "正在取消安装..."
        activeProcess?.terminate()
    }
}
