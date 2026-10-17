import Foundation
import Darwin

/// Detailed status of each environment prerequisite.
public struct EnvironmentReport: Equatable, Sendable {
    public let isAppleSilicon: Bool
    public let pythonPath: String?
    public let pythonVersion: String?
    public let ffmpegPath: String?
    public let ffprobePath: String?
    public let venvPythonPath: String?
    public let hasMlxWhisper: Bool

    public var isHardwareReady: Bool {
        isAppleSilicon
    }

    public var hasRequiredSystemTools: Bool {
        pythonPath != nil && pythonVersion != nil && ffmpegPath != nil && ffprobePath != nil
    }

    public var isVenvReady: Bool {
        venvPythonPath != nil && hasMlxWhisper
    }

    public var isFullyReady: Bool {
        isHardwareReady && hasRequiredSystemTools && isVenvReady
    }

    public var missingPrerequisites: [String] {
        var missing: [String] = []
        if !isAppleSilicon {
            missing.append("当前设备非 Apple Silicon (M 系列芯片)。MLX Whisper 需要 Apple Silicon 架构。")
        }
        if pythonPath == nil {
            missing.append("未找到 Python 3 (建议 3.10+)。可通过 Homebrew 安装：`brew install python@3.11`。")
        }
        if ffmpegPath == nil {
            missing.append("未找到 ffmpeg。请通过 Homebrew 安装：`brew install ffmpeg`。")
        }
        if ffprobePath == nil {
            missing.append("未找到 ffprobe。请通过 Homebrew 安装：`brew install ffmpeg`。")
        }
        return missing
    }
}

public final class EnvironmentChecker: Sendable {
    public static let shared = EnvironmentChecker()

    public init() {}

    /// Checks whether the running machine is Apple Silicon (arm64 architecture).
    public static func checkAppleSilicon() -> Bool {
        #if arch(arm64)
        return true
        #else
        var size: size_t = MemoryLayout<Int32>.size
        var result: Int32 = 0
        if sysctlbyname("hw.optional.arm64", &result, &size, nil, 0) == 0 {
            return result != 0
        }
        return false
        #endif
    }

    /// Finds the first executable matching candidate paths or in standard bin directories.
    public static func findExecutable(named name: String, additionalPaths: [String] = []) -> String? {
        let fileManager = FileManager.default
        var candidates: [String] = []

        // Custom candidates first
        candidates.append(contentsOf: additionalPaths)

        // Standard locations on macOS
        candidates.append("/opt/homebrew/bin/\(name)")
        candidates.append("/usr/local/bin/\(name)")
        candidates.append("/usr/bin/\(name)")
        candidates.append("/bin/\(name)")

        for path in candidates {
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Inspects the Python 3 binary version synchronously without shell strings.
    public static func getPythonVersion(at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return output?.isEmpty == false ? output : nil
        } catch {
            return nil
        }
    }

    /// Checks if a venv directory has a valid python and mlx_whisper installed.
    public static func checkVenv(at venvDirectory: URL) -> (pythonPath: String?, hasMlxWhisper: Bool) {
        let fileManager = FileManager.default
        let pythonBin = venvDirectory.appendingPathComponent("bin/python").path
        guard fileManager.isExecutableFile(atPath: pythonBin) else {
            return (nil, false)
        }

        // Check if mlx_whisper is importable via venv python
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonBin)
        process.arguments = ["-c", "import mlx_whisper; print('OK')"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        var hasMlx = false
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let str = String(data: data, encoding: .utf8), str.contains("OK") {
                    hasMlx = true
                }
            }
        } catch {
            hasMlx = false
        }

        return (pythonBin, hasMlx)
    }

    /// Performs a full environment check and returns an EnvironmentReport.
    public func checkEnvironment(venvURL: URL) -> EnvironmentReport {
        let isAppleSilicon = Self.checkAppleSilicon()
        let pythonPath = Self.findExecutable(named: "python3", additionalPaths: [
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.11",
            "/opt/homebrew/bin/python3.10"
        ])
        let pythonVersion = pythonPath != nil ? Self.getPythonVersion(at: pythonPath!) : nil
        let ffmpegPath = Self.findExecutable(named: "ffmpeg")
        let ffprobePath = Self.findExecutable(named: "ffprobe")
        let venvCheck = Self.checkVenv(at: venvURL)

        return EnvironmentReport(
            isAppleSilicon: isAppleSilicon,
            pythonPath: pythonPath,
            pythonVersion: pythonVersion,
            ffmpegPath: ffmpegPath,
            ffprobePath: ffprobePath,
            venvPythonPath: venvCheck.pythonPath,
            hasMlxWhisper: venvCheck.hasMlxWhisper
        )
    }
}
