import Foundation

@main
struct RouteRuleTests {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    static func main() throws {
        require(isValidManagedIPv4("10.0.0.8"), "valid IPv4")
        require(isValidManagedIPv4("255.255.255.255"), "IPv4 upper bound")
        require(!isValidManagedIPv4("256.1.1.1"), "IPv4 range")
        require(!isValidManagedIPv4("10.0.0"), "short IPv4")
        require(isValidManagedRouteTarget("www.example.com"), "valid domain")
        require(isValidManagedRouteTarget("a-b.example.com"), "hyphenated domain")
        require(!isValidManagedRouteTarget("localhost"), "single-label domain")
        require(!isValidManagedRouteTarget("bad..example.com"), "empty label")
        require(!isValidManagedRouteTarget("-bad.example.com"), "leading hyphen")
        require(!isValidManagedRouteTarget("https://example.com"), "URL rejected")
        require(!isValidManagedRouteTarget("example.com:443"), "port rejected")

        let text = managedRouteConfiguration(target: "www.example.com", interfaceName: "en5",
                                             dns: "1.1.1.1", isEnabled: true)
        let rule = parseManagedRouteRule(id: "fixture", text: text)
        require(rule?.id == "fixture", "rule id")
        require(rule?.target == "www.example.com", "rule target")
        require(rule?.interfaceName == "en5", "rule interface")
        require(rule?.dns == "1.1.1.1", "rule DNS")
        require(rule?.isEnabled == true, "rule enabled state")

        let disabled = parseManagedRouteRule(id: "disabled",
            text: "enabled=0\ninterface=en0\ndns=\nhost=10.0.0.8\n")
        require(disabled?.isEnabled == false, "disabled state")
        require(disabled?.target == "10.0.0.8", "direct IPv4 rule")
        require(parseManagedRouteRule(id: "bad", text: "enabled=1\nhost=example.com\n") == nil,
                "missing interface rejected")

        let migrationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("H3CVPNRouteRuleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: migrationRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: migrationRoot) }
        let legacyURL = migrationRoot.appendingPathComponent("legacy.conf")
        try "enabled=1\ninterface=en5\ndns=1.1.1.1\nhost=one.example.com\nhost=two.example.com\n"
            .write(to: legacyURL, atomically: true, encoding: .utf8)
        try migrateLegacyManagedRouteRules(in: migrationRoot)
        let migratedFiles = try FileManager.default.contentsOfDirectory(at: migrationRoot,
                                                                         includingPropertiesForKeys: nil)
        let migratedRules = migratedFiles.compactMap { url in
            try? String(contentsOf: url, encoding: .utf8)
        }
        require(migratedFiles.count == 2, "multi-host migration file count")
        require(migratedRules.contains { $0.contains("host=one.example.com\n") },
                "multi-host migration keeps first target")
        require(migratedRules.contains { $0.contains("host=two.example.com\n") },
                "multi-host migration keeps second target")

        let backupRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("H3CVPNRouteBackupTests-\(UUID().uuidString)", isDirectory: true)
        let backupRules = backupRoot.appendingPathComponent("rules", isDirectory: true)
        try FileManager.default.createDirectory(at: backupRules, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: backupRoot) }
        let backupRule = backupRules.appendingPathComponent("saved.conf")
        try managedRouteConfiguration(target: "backup.example.com", interfaceName: "en5",
                                      dns: "1.1.1.1", isEnabled: true)
            .write(to: backupRule, atomically: true, encoding: .utf8)
        try synchronizeManagedRouteBackup(in: backupRules)
        let backupDirectory = try managedRouteBackupDirectory(in: backupRules)
        require(backupDirectory.lastPathComponent == ".backup",
                "backup is inside current rules directory")
        try FileManager.default.removeItem(at: backupRule)
        try recoverManagedRouteRulesIfNeeded(in: backupRules)
        require(FileManager.default.fileExists(atPath: backupRule.path),
                "route file recovery from backup")
        print("Route rule tests passed")
    }
}
