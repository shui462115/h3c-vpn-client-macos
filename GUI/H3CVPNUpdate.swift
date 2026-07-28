import Foundation
import CryptoKit

let updateAssetName = "SSLVPNConnect-macOS-arm64.dmg"

struct SemanticVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ rawValue: String) {
        let value = rawValue.hasPrefix("v") ? String(rawValue.dropFirst()) : rawValue
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isNumber && $0.isASCII }),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

struct UpdateRelease: Sendable {
    let version: String
    let assetURL: URL
    let assetSize: Int64
    let sha256: String
    let releaseURL: URL
}

struct PreparedUpdate: Sendable {
    let stagedAppURL: URL
    let destinationAppURL: URL
    let version: String
}

enum UpdateError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft, prerelease, assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: URL
    let size: Int64
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name, size, digest
        case browserDownloadURL = "browser_download_url"
    }
}

private struct UpdateCommandResult: Sendable {
    let status: Int32
    let output: String
}

private func updateCommand(_ executable: String, _ arguments: [String]) throws -> UpdateCommandResult {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return UpdateCommandResult(status: process.terminationStatus,
                               output: String(decoding: data, as: UTF8.self))
}

private func validatedDigest(_ rawValue: String?) throws -> String {
    guard let rawValue, rawValue.hasPrefix("sha256:") else {
        throw UpdateError.message("GitHub 未提供安装包 SHA-256，已停止更新")
    }
    let digest = String(rawValue.dropFirst("sha256:".count)).lowercased()
    guard digest.count == 64,
          digest.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
        throw UpdateError.message("GitHub 返回的安装包 SHA-256 格式不正确")
    }
    return digest
}

private func validateReleaseURL(_ url: URL) throws {
    guard url.scheme == "https", url.host == "github.com",
          url.path.hasPrefix("/shui462115/h3c-vpn-client-macos/releases/download/") else {
        throw UpdateError.message("GitHub 返回了不受信任的下载地址")
    }
}

func latestApplicationUpdate(currentVersion: String) async throws -> UpdateRelease? {
    let endpoint = URL(string: "https://api.github.com/repos/shui462115/h3c-vpn-client-macos/releases/latest")!
    var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                             timeoutInterval: 15)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("SSL-VPN-Connect/\(currentVersion)", forHTTPHeaderField: "User-Agent")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw UpdateError.message("无法读取 GitHub 最新版本信息")
    }
    return try applicationUpdate(from: data, currentVersion: currentVersion)
}

func applicationUpdate(from data: Data, currentVersion: String) throws -> UpdateRelease? {
    guard let current = SemanticVersion(currentVersion) else {
        throw UpdateError.message("当前应用版本格式不正确")
    }
    let release: GitHubRelease
    do {
        release = try JSONDecoder().decode(GitHubRelease.self, from: data)
    } catch {
        throw UpdateError.message("GitHub 最新版本信息无法识别")
    }
    if release.draft || release.prerelease { return nil }
    guard let available = SemanticVersion(release.tagName) else {
        throw UpdateError.message("GitHub 最新版本标记无效")
    }
    guard available > current else { return nil }
    guard let asset = release.assets.first(where: { $0.name == updateAssetName }) else {
        throw UpdateError.message("新版本缺少 \(updateAssetName)")
    }
    guard asset.size > 0, asset.size <= 1_073_741_824 else {
        throw UpdateError.message("GitHub 返回的安装包大小不合理")
    }
    try validateReleaseURL(asset.browserDownloadURL)
    let digest = try validatedDigest(asset.digest)
    return UpdateRelease(version: "\(available.major).\(available.minor).\(available.patch)",
                         assetURL: asset.browserDownloadURL,
                         assetSize: asset.size,
                         sha256: digest,
                         releaseURL: release.htmlURL)
}

private func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
        hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func validateDownloadedUpdate(at url: URL, release: UpdateRelease) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
    guard size == release.assetSize else {
        throw UpdateError.message("安装包大小校验失败，已停止更新")
    }
    guard try sha256(of: url) == release.sha256 else {
        throw UpdateError.message("安装包 SHA-256 校验失败，已停止更新")
    }
}

func downloadApplicationUpdate(_ release: UpdateRelease) async throws -> URL {
    var request = URLRequest(url: release.assetURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                             timeoutInterval: 120)
    request.setValue("SSL-VPN-Connect-Updater", forHTTPHeaderField: "User-Agent")
    let (temporaryURL, response) = try await URLSession.shared.download(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw UpdateError.message("下载新版安装包失败")
    }

    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent("com.codex.h3cvpn-update-\(UUID().uuidString)", isDirectory: true)
    do {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        let dmgURL = directory.appendingPathComponent(updateAssetName)
        try fileManager.moveItem(at: temporaryURL, to: dmgURL)
        try validateDownloadedUpdate(at: dmgURL, release: release)
        return dmgURL
    } catch {
        try? fileManager.removeItem(at: directory)
        throw error
    }
}

private func plist(at appURL: URL) throws -> [String: Any] {
    let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
    let data = try Data(contentsOf: infoURL)
    guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        throw UpdateError.message("新版应用的 Info.plist 无法识别")
    }
    return value
}

func validateUpdateApplication(at appURL: URL, expectedVersion: String) throws {
    let values = try appURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw UpdateError.message("新版应用目录无效")
    }
    let info = try plist(at: appURL)
    guard info["CFBundleIdentifier"] as? String == "com.codex.h3cvpn",
          info["CFBundleShortVersionString"] as? String == expectedVersion,
          info["CFBundleExecutable"] as? String == "H3CVPN" else {
        throw UpdateError.message("新版应用身份或版本校验失败")
    }
    let executable = appURL.appendingPathComponent("Contents/MacOS/H3CVPN")
    let architecture = try updateCommand("/usr/bin/lipo", ["-archs", executable.path])
    guard architecture.status == 0,
          architecture.output.split(whereSeparator: { $0.isWhitespace }).map(String.init) == ["arm64"] else {
        throw UpdateError.message("新版应用不是预期的 arm64 架构")
    }
    let signature = try updateCommand("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path])
    guard signature.status == 0 else {
        throw UpdateError.message("新版应用代码签名校验失败")
    }
}

func prepareApplicationUpdate(dmgURL: URL, release: UpdateRelease,
                              currentAppURL: URL) async throws -> PreparedUpdate {
    try await Task.detached {
        let fileManager = FileManager.default
        let downloadDirectory = dmgURL.deletingLastPathComponent()
        defer { try? fileManager.removeItem(at: downloadDirectory) }

        let mountDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("com.codex.h3cvpn-mount-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: mountDirectory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: mountDirectory) }

        let attach = try updateCommand("/usr/bin/hdiutil", ["attach", dmgURL.path, "-readonly", "-nobrowse",
                                                               "-mountpoint", mountDirectory.path])
        guard attach.status == 0 else {
            throw UpdateError.message("无法挂载新版安装包")
        }
        defer { _ = try? updateCommand("/usr/bin/hdiutil", ["detach", mountDirectory.path, "-force"]) }

        let mountedApp = mountDirectory.appendingPathComponent("SSL VPN Connect.app", isDirectory: true)
        try validateUpdateApplication(at: mountedApp, expectedVersion: release.version)

        let destination = currentAppURL.resolvingSymlinksInPath().standardizedFileURL
        guard destination.pathExtension == "app" else {
            throw UpdateError.message("当前程序不是标准 .app，无法自动覆盖")
        }
        let parent = destination.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: parent.path) else {
            throw UpdateError.message("没有权限覆盖 \(destination.path)，请从 DMG 手动拖入应用程序文件夹")
        }
        let staged = parent.appendingPathComponent(".SSL VPN Connect.update-\(UUID().uuidString).app",
                                                   isDirectory: true)
        do {
            try fileManager.copyItem(at: mountedApp, to: staged)
            try validateUpdateApplication(at: staged, expectedVersion: release.version)
            return PreparedUpdate(stagedAppURL: staged, destinationAppURL: destination,
                                  version: release.version)
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }
    }.value
}

func launchApplicationUpdater(_ update: PreparedUpdate) throws {
    guard let updater = Bundle.main.url(forResource: "H3CVPNUpdater", withExtension: nil) else {
        throw UpdateError.message("应用缺少独立更新器")
    }
    let process = Process()
    process.executableURL = updater
    process.arguments = ["--staged", update.stagedAppURL.path,
                         "--destination", update.destinationAppURL.path,
                         "--version", update.version,
                         "--pid", String(getpid())]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
}
