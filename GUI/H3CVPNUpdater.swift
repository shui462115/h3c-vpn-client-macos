import Foundation
import Darwin

private enum UpdaterError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

private struct Arguments {
    let staged: URL
    let destination: URL
    let version: String
    let pid: pid_t

    init(_ values: [String]) throws {
        var options: [String: String] = [:]
        var index = 1
        while index + 1 < values.count {
            options[values[index]] = values[index + 1]
            index += 2
        }
        guard index == values.count,
              let staged = options["--staged"],
              let destination = options["--destination"],
              let version = options["--version"],
              let rawPID = options["--pid"], let pid = pid_t(rawPID), pid > 1 else {
            throw UpdaterError.message("更新器参数无效")
        }
        self.staged = URL(fileURLWithPath: staged).standardizedFileURL
        self.destination = URL(fileURLWithPath: destination).standardizedFileURL
        self.version = version
        self.pid = pid
    }
}

private func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

private func info(at app: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
    guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        throw UpdaterError.message("无法读取新版应用信息")
    }
    return value
}

private func validate(_ arguments: Arguments) throws {
    let fileManager = FileManager.default
    guard arguments.staged.deletingLastPathComponent() == arguments.destination.deletingLastPathComponent(),
          arguments.staged.lastPathComponent.hasPrefix(".SSL VPN Connect.update-"),
          arguments.staged.pathExtension == "app", arguments.destination.pathExtension == "app",
          fileManager.fileExists(atPath: arguments.destination.path) else {
        throw UpdaterError.message("更新路径校验失败")
    }
    let values = try info(at: arguments.staged)
    guard values["CFBundleIdentifier"] as? String == "com.codex.h3cvpn",
          values["CFBundleShortVersionString"] as? String == arguments.version,
          values["CFBundleExecutable"] as? String == "H3CVPN" else {
        throw UpdaterError.message("新版应用身份校验失败")
    }
    guard try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", arguments.staged.path]) == 0 else {
        throw UpdaterError.message("新版应用签名校验失败")
    }
}

private func waitForExit(pid: pid_t, timeout: TimeInterval = 30) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while kill(pid, 0) == 0 || errno == EPERM {
        guard Date() < deadline else {
            throw UpdaterError.message("旧版应用未能及时退出")
        }
        usleep(100_000)
    }
    guard errno == ESRCH else {
        throw UpdaterError.message("无法确认旧版应用状态")
    }
}

private func appendLog(_ message: String) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("com.codex.h3cvpn-updater.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

private func install(_ arguments: Arguments) throws {
    try validate(arguments)
    try waitForExit(pid: arguments.pid)

    guard renamex_np(arguments.staged.path, arguments.destination.path, UInt32(RENAME_SWAP)) == 0 else {
        throw UpdaterError.message("覆盖应用失败：\(String(cString: strerror(errno)))")
    }
    let oldApp = arguments.staged
    if (try? run("/usr/bin/open", [arguments.destination.path])) != 0 {
        _ = renamex_np(arguments.destination.path, oldApp.path, UInt32(RENAME_SWAP))
        throw UpdaterError.message("新版应用无法重新打开，已恢复旧版")
    }
    try? FileManager.default.removeItem(at: oldApp)
}

private var recoveryArguments: Arguments?
do {
    let arguments = try Arguments(CommandLine.arguments)
    recoveryArguments = arguments
    try install(arguments)
    appendLog("更新到 \(arguments.version) 成功")
} catch {
    appendLog("更新失败：\(error.localizedDescription)")
    if let arguments = recoveryArguments,
       FileManager.default.fileExists(atPath: arguments.destination.path) {
        try? waitForExit(pid: arguments.pid, timeout: 5)
        _ = try? run("/usr/bin/open", [arguments.destination.path])
    }
    exit(EXIT_FAILURE)
}
