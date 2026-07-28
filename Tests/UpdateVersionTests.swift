import Foundation

@main
struct UpdateVersionTests {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func releaseJSON(tag: String, prerelease: Bool = false,
                                    digest: String = String(repeating: "a", count: 64)) -> Data {
        let value: [String: Any] = [
            "tag_name": tag,
            "html_url": "https://github.com/shui462115/h3c-vpn-client-macos/releases/tag/\(tag)",
            "draft": false,
            "prerelease": prerelease,
            "assets": [[
                "name": updateAssetName,
                "browser_download_url": "https://github.com/shui462115/h3c-vpn-client-macos/releases/download/\(tag)/\(updateAssetName)",
                "size": 1024,
                "digest": "sha256:\(digest)"
            ]]
        ]
        return try! JSONSerialization.data(withJSONObject: value)
    }

    static func main() throws {
        require(SemanticVersion("v0.9.4") == SemanticVersion("0.9.4"), "v prefix")
        require(SemanticVersion("1.0.0")! > SemanticVersion("0.99.99")!, "major comparison")
        require(SemanticVersion("0.10.0")! > SemanticVersion("0.9.99")!, "minor comparison")
        require(SemanticVersion("0.9.10")! > SemanticVersion("0.9.9")!, "patch comparison")
        require(SemanticVersion("0.9") == nil, "short version rejected")
        require(SemanticVersion("0.9.4-beta") == nil, "prerelease syntax rejected")

        let current = try applicationUpdate(from: releaseJSON(tag: "v0.9.4"), currentVersion: "0.9.4")
        require(current == nil, "current release ignored")
        let newer = try applicationUpdate(from: releaseJSON(tag: "v0.9.5"), currentVersion: "0.9.4")
        require(newer?.version == "0.9.5", "newer release accepted")
        let prerelease = try applicationUpdate(from: releaseJSON(tag: "v0.9.5", prerelease: true),
                                               currentVersion: "0.9.4")
        require(prerelease == nil, "prerelease ignored")

        do {
            _ = try applicationUpdate(from: releaseJSON(tag: "latest"), currentVersion: "0.9.4")
            require(false, "malformed tag rejected")
        } catch { }
        do {
            _ = try applicationUpdate(from: releaseJSON(tag: "v0.9.5", digest: "bad"),
                                      currentVersion: "0.9.4")
            require(false, "malformed digest rejected")
        } catch { }
        print("Update version tests passed")
    }
}
