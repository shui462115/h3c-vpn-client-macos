import Foundation

@main
struct UpdatePackageTests {
    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
        exit(EXIT_FAILURE)
    }

    private static func mustThrow(_ message: String, _ operation: () throws -> Void) {
        do {
            try operation()
            fail(message)
        } catch { }
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 4 else {
            fail("usage: UpdatePackageTests APP DMG SHA256")
        }
        let app = URL(fileURLWithPath: CommandLine.arguments[1])
        let dmg = URL(fileURLWithPath: CommandLine.arguments[2])
        let digest = CommandLine.arguments[3]
        let size = ((try FileManager.default.attributesOfItem(atPath: dmg.path)[.size]) as! NSNumber).int64Value
        let release = UpdateRelease(
            version: "0.9.5",
            assetURL: URL(string: "https://github.com/shui462115/h3c-vpn-client-macos/releases/download/v0.9.5/\(updateAssetName)")!,
            assetSize: size,
            sha256: digest,
            releaseURL: URL(string: "https://github.com/shui462115/h3c-vpn-client-macos/releases/tag/v0.9.5")!
        )

        try validateDownloadedUpdate(at: dmg, release: release)
        var badDigest = release
        badDigest = UpdateRelease(version: badDigest.version, assetURL: badDigest.assetURL,
                                  assetSize: badDigest.assetSize,
                                  sha256: String(repeating: "0", count: 64),
                                  releaseURL: badDigest.releaseURL)
        mustThrow("checksum mismatch accepted") {
            try validateDownloadedUpdate(at: dmg, release: badDigest)
        }
        let badSize = UpdateRelease(version: release.version, assetURL: release.assetURL,
                                    assetSize: release.assetSize + 1, sha256: release.sha256,
                                    releaseURL: release.releaseURL)
        mustThrow("size mismatch accepted") {
            try validateDownloadedUpdate(at: dmg, release: badSize)
        }

        try validateUpdateApplication(at: app, expectedVersion: "0.9.5")
        mustThrow("wrong expected version accepted") {
            try validateUpdateApplication(at: app, expectedVersion: "9.9.9")
        }

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("h3cvpn-package-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let wrongIdentity = workspace.appendingPathComponent("Wrong Identity.app", isDirectory: true)
        try FileManager.default.copyItem(at: app, to: wrongIdentity)
        let wrongInfoURL = wrongIdentity.appendingPathComponent("Contents/Info.plist")
        var wrongInfo = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: wrongInfoURL), format: nil
        ) as! [String: Any]
        wrongInfo["CFBundleIdentifier"] = "invalid.bundle.identifier"
        try PropertyListSerialization.data(fromPropertyList: wrongInfo, format: .xml, options: 0)
            .write(to: wrongInfoURL, options: .atomic)
        mustThrow("wrong bundle identifier accepted") {
            try validateUpdateApplication(at: wrongIdentity, expectedVersion: "0.9.5")
        }

        let brokenSignature = workspace.appendingPathComponent("Broken Signature.app", isDirectory: true)
        try FileManager.default.copyItem(at: app, to: brokenSignature)
        let readme = brokenSignature.appendingPathComponent("Contents/Resources/README.md")
        let handle = try FileHandle(forWritingTo: readme)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\nsignature test\n".utf8))
        try handle.close()
        mustThrow("broken code signature accepted") {
        try validateUpdateApplication(at: brokenSignature, expectedVersion: "0.9.5")
        }

        let current = workspace.appendingPathComponent("SSL VPN Connect.app", isDirectory: true)
        try FileManager.default.copyItem(at: app, to: current)
        let downloadDirectory = workspace.appendingPathComponent("download", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: false)
        let dmgCopy = downloadDirectory.appendingPathComponent(updateAssetName)
        try FileManager.default.copyItem(at: dmg, to: dmgCopy)
        let prepared = try await prepareApplicationUpdate(dmgURL: dmgCopy, release: release,
                                                          currentAppURL: current)
        guard FileManager.default.fileExists(atPath: prepared.stagedAppURL.path) else {
            fail("validated app was not staged")
        }
        try validateUpdateApplication(at: prepared.stagedAppURL, expectedVersion: release.version)
        try FileManager.default.removeItem(at: prepared.stagedAppURL)
        print("Update package tests passed")
    }
}
