import Foundation

@main
struct UpdaterIntegrationTests {
    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
        exit(EXIT_FAILURE)
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func createApp(at url: URL, version: String, executable: URL) throws {
        let fileManager = FileManager.default
        let macOS = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.copyItem(at: executable, to: macOS.appendingPathComponent("H3CVPN"))
        let info: [String: Any] = [
            "CFBundleDevelopmentRegion": "zh_CN",
            "CFBundleDisplayName": "Updater Fixture",
            "CFBundleIdentifier": "com.codex.h3cvpn",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": "1",
            "CFBundleExecutable": "H3CVPN",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "Updater Fixture",
            "CFBundlePackageType": "APPL",
            "LSMinimumSystemVersion": "13.0",
            "NSPrincipalClass": "NSApplication",
            "LSBackgroundOnly": true
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"), options: .atomic)
        guard try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", url.path]) == 0 else {
            fail("could not sign fixture app")
        }
    }

    private static func version(at app: URL) throws -> String? {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return info?["CFBundleShortVersionString"] as? String
    }

    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fail("usage: UpdaterIntegrationTests UPDATER FIXTURE_EXECUTABLE")
        }
        let updater = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let fixture = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("h3cvpn-updater-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let destination = workspace.appendingPathComponent("SSL VPN Connect.app", isDirectory: true)
        let staged = workspace.appendingPathComponent(".SSL VPN Connect.update-fixture.app", isDirectory: true)
        try createApp(at: destination, version: "0.9.3", executable: fixture)
        try createApp(at: staged, version: "0.9.4", executable: fixture)

        let blocker = Process()
        blocker.executableURL = URL(fileURLWithPath: "/bin/sleep")
        blocker.arguments = ["0.3"]
        try blocker.run()

        let process = Process()
        process.executableURL = updater
        process.arguments = ["--staged", staged.path, "--destination", destination.path,
                             "--version", "0.9.4", "--pid", String(blocker.processIdentifier)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { fail("updater exited with \(process.terminationStatus)") }
        guard try version(at: destination) == "0.9.4" else { fail("destination was not replaced") }
        guard !FileManager.default.fileExists(atPath: staged.path) else { fail("old app was not removed") }
        print("Updater integration tests passed")
    }
}
