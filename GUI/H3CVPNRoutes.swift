import SwiftUI
import AppKit
import Foundation

private let routeManagerVersionPath = "/Library/Application Support/LocalRouteManager/daemon-version"
private let routeManagerScriptPath = "/usr/local/sbin/local-route-manager.sh"
private let routeManagerPlistPath = "/Library/LaunchDaemons/com.codex.local-route-manager.plist"
private let routeManagerStatusPath = "/var/run/com.codex.local-route-manager.status"
private let currentRouteManagerVersion = "6"

struct ManagedRouteRule: Identifiable, Hashable, Sendable {
    let id: String
    var target: String
    var interfaceName: String
    var dns: String
    var isEnabled: Bool
}

struct RouteInterfaceOption: Identifiable, Hashable, Sendable {
    var id: String { device }
    let displayName: String
    let device: String
}

private struct RouteCommandResult: Sendable {
    let status: Int32
    let output: String
}

private struct RouteDaemonStatus: Sendable {
    let modifiedAt: Date?
    let enabled: Int
    let managed: Int
    let errors: Int
}

func isValidManagedIPv4(_ value: String) -> Bool {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return false }
    return parts.allSatisfy { part in
        !part.isEmpty && part.count <= 3 && part.allSatisfy { $0.isNumber && $0.isASCII } &&
            (Int(part).map { $0 <= 255 } ?? false)
    }
}

func isValidManagedRouteTarget(_ value: String) -> Bool {
    if isValidManagedIPv4(value) { return true }
    guard !value.isEmpty, value.utf8.count <= 253,
          !value.hasPrefix("."), !value.hasSuffix(".") else { return false }
    let labels = value.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2 else { return false }
    return labels.allSatisfy { label in
        guard !label.isEmpty, label.utf8.count <= 63,
              label.first?.isLetter == true || label.first?.isNumber == true,
              label.last?.isLetter == true || label.last?.isNumber == true else { return false }
        return label.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-")
        }
    }
}

func parseManagedRouteRule(id: String, text: String) -> ManagedRouteRule? {
    var target = ""
    var interfaceName = ""
    var dns = ""
    var isEnabled = true
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if line.hasPrefix("host=") { target = String(line.dropFirst(5)) }
        else if line.hasPrefix("interface=") { interfaceName = String(line.dropFirst(10)) }
        else if line.hasPrefix("dns=") { dns = String(line.dropFirst(4)) }
        else if line.hasPrefix("enabled=") { isEnabled = String(line.dropFirst(8)) != "0" }
    }
    guard !target.isEmpty, !interfaceName.isEmpty else { return nil }
    return ManagedRouteRule(id: id, target: target, interfaceName: interfaceName,
                            dns: dns, isEnabled: isEnabled)
}

func managedRouteConfiguration(target: String, interfaceName: String,
                               dns: String, isEnabled: Bool) -> String {
    "enabled=\(isEnabled ? 1 : 0)\ninterface=\(interfaceName)\ndns=\(dns)\nhost=\(target)\n"
}

func migrateLegacyManagedRouteRules(in directory: URL,
                                    fileManager: FileManager = .default) throws {
    let files = try fileManager.contentsOfDirectory(at: directory,
                                                    includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "conf" }
    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hosts = lines.filter { $0.hasPrefix("host=") && $0.count > 5 }
            .map { String($0.dropFirst(5)) }
        guard hosts.count > 1 else { continue }
        let enabled = lines.first(where: { $0.hasPrefix("enabled=") })
            .map { String($0.dropFirst(8)) } ?? "1"
        let interfaceName = lines.first(where: { $0.hasPrefix("interface=") })
            .map { String($0.dropFirst(10)) } ?? "en5"
        let dns = lines.first(where: { $0.hasPrefix("dns=") })
            .map { String($0.dropFirst(4)) } ?? ""
        let baseID = file.deletingPathExtension().lastPathComponent

        // Create additional rules first, then atomically replace the legacy file
        // with its first target so an interrupted migration cannot lose that target.
        for (index, host) in hosts.enumerated().dropFirst() {
            var ruleID = "\(baseID)-\(index + 1)"
            var destination = directory.appendingPathComponent(ruleID).appendingPathExtension("conf")
            while fileManager.fileExists(atPath: destination.path) {
                ruleID = "rule-\(UUID().uuidString.lowercased())"
                destination = directory.appendingPathComponent(ruleID).appendingPathExtension("conf")
            }
            let configuration = "enabled=\(enabled)\ninterface=\(interfaceName)\ndns=\(dns)\nhost=\(host)\n"
            try configuration.write(to: destination, atomically: true, encoding: .utf8)
            try? fileManager.setAttributes([.posixPermissions: 0o600],
                                           ofItemAtPath: destination.path)
        }
        let firstConfiguration = "enabled=\(enabled)\ninterface=\(interfaceName)\ndns=\(dns)\nhost=\(hosts[0])\n"
        try firstConfiguration.write(to: file, atomically: true, encoding: .utf8)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

private func runRouteCommand(_ executable: String, _ arguments: [String]) throws -> RouteCommandResult {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return RouteCommandResult(status: process.terminationStatus,
                              output: String(decoding: data, as: UTF8.self))
}

private func routeShellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

private func routeAppleScriptLiteral(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
}

private func routeRulesDirectory() throws -> URL {
    let root = try FileManager.default.url(for: .applicationSupportDirectory,
                                           in: .userDomainMask,
                                           appropriateFor: nil,
                                           create: true)
    let directory = root.appendingPathComponent("LocalRouteManager/rules", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    return directory
}

func managedRouteBackupDirectory(in rulesDirectory: URL,
                                 fileManager: FileManager = .default) throws -> URL {
    let backup = rulesDirectory.appendingPathComponent(".backup", isDirectory: true)
    try fileManager.createDirectory(at: backup, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
    try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backup.path)

    // v0.9.8 briefly stored backups beside the rules directory. Move valid
    // files into the current-directory backup before using the new location.
    let legacy = rulesDirectory.deletingLastPathComponent()
        .appendingPathComponent("rules-backup", isDirectory: true)
    let currentFiles = (try? fileManager.contentsOfDirectory(at: backup,
                                                              includingPropertiesForKeys: nil)) ?? []
        .filter(isManagedRouteFile)
    if currentFiles.isEmpty,
       let legacyFiles = try? fileManager.contentsOfDirectory(at: legacy,
                                                              includingPropertiesForKeys: nil) {
        for file in legacyFiles.filter(isManagedRouteFile) {
            let destination = backup.appendingPathComponent(file.lastPathComponent)
            if !fileManager.fileExists(atPath: destination.path) {
                try? fileManager.copyItem(at: file, to: destination)
                try? fileManager.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: destination.path)
            }
        }
    }
    return backup
}

private func isManagedRouteFile(_ url: URL) -> Bool {
    guard url.pathExtension == "conf" else { return false }
    return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
}

func synchronizeManagedRouteBackup(in rulesDirectory: URL,
                                   fileManager: FileManager = .default) throws {
    let backup = try managedRouteBackupDirectory(in: rulesDirectory, fileManager: fileManager)
    let files = try fileManager.contentsOfDirectory(at: rulesDirectory,
                                                    includingPropertiesForKeys: nil)
        .filter(isManagedRouteFile)
    for file in files {
        let destination = backup.appendingPathComponent(file.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: file, to: destination)
        try? fileManager.setAttributes([.posixPermissions: 0o600],
                                       ofItemAtPath: destination.path)
    }
}

func recoverManagedRouteRulesIfNeeded(in rulesDirectory: URL,
                                      fileManager: FileManager = .default) throws {
    let primary = try fileManager.contentsOfDirectory(at: rulesDirectory,
                                                      includingPropertiesForKeys: nil)
        .filter(isManagedRouteFile)
    guard primary.isEmpty else { return }
    let backup = try managedRouteBackupDirectory(in: rulesDirectory, fileManager: fileManager)
    let backups = try fileManager.contentsOfDirectory(at: backup,
                                                      includingPropertiesForKeys: nil)
        .filter(isManagedRouteFile)
    for file in backups {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              parseManagedRouteRule(id: file.deletingPathExtension().lastPathComponent,
                                   text: text) != nil else { continue }
        let destination = rulesDirectory.appendingPathComponent(file.lastPathComponent)
        try fileManager.copyItem(at: file, to: destination)
        try? fileManager.setAttributes([.posixPermissions: 0o600],
                                       ofItemAtPath: destination.path)
    }
}

private func availableRouteInterfaces() throws -> [RouteInterfaceOption] {
    let result = try runRouteCommand("/usr/sbin/networksetup", ["-listallhardwareports"])
    guard result.status == 0 else { return [] }
    var options: [RouteInterfaceOption] = []
    var hardwarePort: String?
    for line in result.output.split(separator: "\n").map(String.init) {
        if line.hasPrefix("Hardware Port:") {
            hardwarePort = String(line.dropFirst("Hardware Port:".count))
                .trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("Device:"), let hardwarePort {
            let device = String(line.dropFirst("Device:".count)).trimmingCharacters(in: .whitespaces)
            if !device.isEmpty, !options.contains(where: { $0.device == device }) {
                options.append(RouteInterfaceOption(displayName: hardwarePort, device: device))
            }
        }
    }
    return options
}

private func routeDaemonStatus() -> RouteDaemonStatus? {
    let fileManager = FileManager.default
    let attributes = try? fileManager.attributesOfItem(atPath: routeManagerStatusPath)
    let modifiedAt = attributes?[.modificationDate] as? Date
    guard let text = try? String(contentsOfFile: routeManagerStatusPath, encoding: .utf8) else {
        return nil
    }
    var enabled = 0
    var managed = 0
    var errors = 0
    for line in text.split(separator: "\n") {
        if line.hasPrefix("enabled=") { enabled = Int(line.dropFirst(8)) ?? 0 }
        else if line.hasPrefix("managed=") { managed = Int(line.dropFirst(8)) ?? 0 }
        else if line.hasPrefix("errors=") { errors = Int(line.dropFirst(7)) ?? 0 }
    }
    return RouteDaemonStatus(modifiedAt: modifiedAt, enabled: enabled,
                             managed: managed, errors: errors)
}

private func routeServiceIsCurrent() -> Bool {
    let version = (try? String(contentsOfFile: routeManagerVersionPath, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let fileManager = FileManager.default
    guard version == currentRouteManagerVersion &&
        fileManager.fileExists(atPath: routeManagerScriptPath) &&
        fileManager.fileExists(atPath: routeManagerPlistPath) else { return false }
    guard let plistData = fileManager.contents(atPath: routeManagerPlistPath),
          let plist = try? PropertyListSerialization.propertyList(from: plistData,
                                                                  format: nil) as? [String: Any],
          let arguments = plist["ProgramArguments"] as? [String],
          let rulesIndex = arguments.firstIndex(of: "--rules"),
          arguments.indices.contains(rulesIndex + 1),
          let expectedRules = try? routeRulesDirectory().standardizedFileURL.path,
          URL(fileURLWithPath: arguments[rulesIndex + 1]).standardizedFileURL.path == expectedRules
    else { return false }
    let service = try? runRouteCommand("/bin/launchctl",
                                       ["print", "system/com.codex.local-route-manager"])
    return service?.status == 0
}

private func runRouteAdministratorAction(_ action: String, rulesDirectory: String) throws -> String {
    guard let installer = Bundle.main.url(forResource: "install-route-manager", withExtension: "sh"),
          Bundle.main.url(forResource: "local-route-manager", withExtension: "sh") != nil else {
        throw NSError(domain: "H3CVPNRoutes", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "应用缺少本地路由服务组件"])
    }
    let command = "/bin/sh \(routeShellQuote(installer.path)) \(routeShellQuote(action)) " +
        "\(routeShellQuote(rulesDirectory)) \(getuid())"
    let source = "do shell script \(routeAppleScriptLiteral(command)) with administrator privileges"
    let result = try runRouteCommand("/usr/bin/osascript", ["-e", source])
    guard result.status == 0 else {
        throw NSError(domain: "H3CVPNRoutes", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: result.output.isEmpty
                                ? "管理员授权被取消" : result.output])
    }
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
}

@MainActor
final class LocalRouteManagerViewModel: ObservableObject {
    @Published private(set) var rules: [ManagedRouteRule] = []
    @Published private(set) var interfaces: [RouteInterfaceOption] = []
    @Published var selectedRuleID: String?
    @Published var target = ""
    @Published var interfaceName = ""
    @Published var dns = ""
    @Published var isEnabled = true
    @Published private(set) var statusText = "正在读取本地路由配置…"
    @Published private(set) var routeServiceReady = false
    @Published private(set) var isBusy = false

    private var pollingGeneration = UUID()

    var enabledRuleCount: Int { rules.filter(\.isEnabled).count }
    var canDelete: Bool { selectedRuleID != nil }
    var serviceTitle: String { routeServiceReady ? "后台路由服务已安装" : "需要安装后台路由服务" }

    init() {
        reloadRules()
        refreshServiceState()
        refreshInterfaces()
    }

    func activate() {
        reloadRules(selecting: selectedRuleID)
        refreshServiceState()
        refreshInterfaces()
    }

    func refreshInterfaces() {
        Task {
            let loaded = await Task.detached { (try? availableRouteInterfaces()) ?? [] }.value
            interfaces = loaded
            if interfaceName.isEmpty { interfaceName = loaded.first?.device ?? "" }
        }
    }

    func selectRule(_ id: String?) {
        selectedRuleID = id
        guard let id, let rule = rules.first(where: { $0.id == id }) else { return }
        loadDraft(rule)
        statusText = "已选择规则，可编辑后保存并应用"
    }

    func newRule() {
        selectedRuleID = nil
        target = ""
        dns = ""
        isEnabled = true
        if interfaceName.isEmpty { interfaceName = interfaces.first?.device ?? "" }
        statusText = "请输入一个域名或 IPv4 地址"
    }

    func saveAndApply() {
        guard !isBusy else { return }
        let cleanedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedDNS = dns.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidManagedRouteTarget(cleanedTarget), !interfaceName.isEmpty,
              cleanedDNS.isEmpty || isValidManagedIPv4(cleanedDNS) else {
            statusText = "目标地址、DNS 或网卡格式不正确"
            return
        }
        do {
            let directory = try routeRulesDirectory()
            let ruleID = selectedRuleID ?? "rule-\(UUID().uuidString.lowercased())"
            let normalizedTarget = isValidManagedIPv4(cleanedTarget)
                ? cleanedTarget : cleanedTarget.lowercased()
            let configuration = managedRouteConfiguration(target: normalizedTarget,
                                                          interfaceName: interfaceName,
                                                          dns: cleanedDNS,
                                                          isEnabled: isEnabled)
            let url = directory.appendingPathComponent(ruleID).appendingPathExtension("conf")
            try configuration.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path)
            try synchronizeManagedRouteBackup(in: directory)
            reloadRules(selecting: ruleID)
            syncRules(directory: directory)
        } catch {
            statusText = "保存规则失败：\(error.localizedDescription)"
        }
    }

    func deleteSelectedRule() {
        guard let selectedRuleID else { return }
        do {
            let directory = try routeRulesDirectory()
            let url = directory.appendingPathComponent(selectedRuleID).appendingPathExtension("conf")
            try FileManager.default.removeItem(at: url)
            let backup = try managedRouteBackupDirectory(in: directory)
            try? FileManager.default.removeItem(at: backup.appendingPathComponent(url.lastPathComponent))
            self.selectedRuleID = nil
            reloadRules()
            syncRules(directory: directory)
        } catch {
            statusText = "删除规则失败：\(error.localizedDescription)"
        }
    }

    func installOrUpdateService() {
        guard !isBusy else { return }
        do {
            let directory = try routeRulesDirectory()
            installService(action: "install", rulesDirectory: directory.path)
        } catch {
            statusText = "无法准备规则目录：\(error.localizedDescription)"
        }
    }

    func restoreAndUninstallService() {
        guard !isBusy else { return }
        installService(action: "restore", rulesDirectory: "")
    }

    func refreshServiceState() {
        routeServiceReady = routeServiceIsCurrent()
        if let snapshot = routeDaemonStatus(), routeServiceReady {
            statusText = statusDescription(snapshot)
        } else if !routeServiceReady {
            statusText = rules.isEmpty ? "尚未配置固定路由" : "应用规则时将请求一次管理员授权"
        }
    }

    private func loadDraft(_ rule: ManagedRouteRule) {
        target = rule.target
        interfaceName = rule.interfaceName
        dns = rule.dns
        isEnabled = rule.isEnabled
    }

    private func reloadRules(selecting preferredID: String? = nil) {
        do {
            let directory = try routeRulesDirectory()
            try recoverManagedRouteRulesIfNeeded(in: directory)
            try migrateLegacyManagedRouteRules(in: directory)
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                    includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "conf" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for file in files {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: file.path)
            }
            try synchronizeManagedRouteBackup(in: directory)
            rules = files.compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return parseManagedRouteRule(id: url.deletingPathExtension().lastPathComponent, text: text)
            }
            let selection = preferredID.flatMap { id in rules.contains(where: { $0.id == id }) ? id : nil }
                ?? rules.first?.id
            selectedRuleID = selection
            if let selection, let rule = rules.first(where: { $0.id == selection }) {
                loadDraft(rule)
            } else {
                target = ""
                dns = ""
                isEnabled = true
                if interfaceName.isEmpty { interfaceName = interfaces.first?.device ?? "" }
            }
        } catch {
            statusText = "读取规则失败：\(error.localizedDescription)"
        }
    }

    private func syncRules(directory: URL) {
        if routeServiceIsCurrent() {
            routeServiceReady = true
            statusText = "规则已保存，正在后台应用 \(enabledRuleCount) 条规则…"
            beginPolling(since: Date())
        } else {
            installService(action: "install", rulesDirectory: directory.path)
        }
    }

    private func installService(action: String, rulesDirectory: String) {
        isBusy = true
        statusText = action == "restore" ? "正在恢复系统路由并卸载后台服务…" :
            "首次使用需要一次管理员授权…"
        Task {
            do {
                _ = try await Task.detached {
                    try runRouteAdministratorAction(action, rulesDirectory: rulesDirectory)
                }.value
                isBusy = false
                routeServiceReady = action != "restore"
                if action == "restore" {
                    pollingGeneration = UUID()
                    statusText = "已恢复并卸载；规则文件仍保留"
                } else {
                    statusText = "路由服务已安装，正在应用规则…"
                    beginPolling(since: Date().addingTimeInterval(-1))
                }
            } catch {
                isBusy = false
                routeServiceReady = routeServiceIsCurrent()
                statusText = "操作失败：\(error.localizedDescription)"
            }
        }
    }

    private func beginPolling(since startDate: Date) {
        let generation = UUID()
        pollingGeneration = generation
        Task {
            for _ in 0..<24 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard pollingGeneration == generation else { return }
                let snapshot = await Task.detached { routeDaemonStatus() }.value
                if let snapshot, let modifiedAt = snapshot.modifiedAt,
                   modifiedAt.timeIntervalSince(startDate) >= -0.25 {
                    statusText = statusDescription(snapshot)
                    return
                }
            }
            guard pollingGeneration == generation else { return }
            statusText = "规则已保存，后台任务将在数秒内继续同步"
        }
    }

    private func statusDescription(_ snapshot: RouteDaemonStatus) -> String {
        if snapshot.errors > 0 {
            return "已处理 \(snapshot.enabled) 条规则；\(snapshot.errors) 条暂未生效"
        }
        return "已应用 \(snapshot.enabled) 条规则，管理 \(snapshot.managed) 个主机路由"
    }
}

struct LocalRouteManagerView: View {
    @ObservedObject var model: LocalRouteManagerViewModel
    var embedded = false
    @State private var showDeleteConfirmation = false
    @State private var showRestoreConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: embedded ? 9 : 14) {
            HStack(spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 44, height: 44)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("本地网络路由配置").font(.title3.weight(.semibold))
                    Text("将任意域名或 IPv4 地址固定到指定本地网卡")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label(model.routeServiceReady ? "服务已就绪" : "服务未安装",
                      systemImage: model.routeServiceReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(model.routeServiceReady ? .green : .orange)
            }

            GroupBox {
                if model.rules.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch").font(.title2).foregroundStyle(.secondary)
                        Text("尚未配置固定路由").font(.callout.weight(.medium))
                        Text("点击“新建规则”添加第一个目标地址。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 112)
                } else {
                    List(selection: Binding(
                        get: { model.selectedRuleID },
                        set: { model.selectRule($0) }
                    )) {
                        ForEach(model.rules) { rule in
                            HStack(spacing: 10) {
                                Circle().fill(rule.isEnabled ? Color.green : Color.gray.opacity(0.55))
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.target)
                                        .font(.system(.body, design: .monospaced))
                                        .lineLimit(1)
                                    Text("固定到 \(rule.interfaceName)" +
                                         (rule.dns.isEmpty ? " · 自动 DNS" : " · DNS \(rule.dns)"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(rule.isEnabled ? "已启用" : "已停用")
                                    .font(.caption).foregroundStyle(rule.isEnabled ? .green : .secondary)
                            }
                            .tag(rule.id)
                        }
                    }
                    .listStyle(.inset)
                    .frame(height: embedded ? 116 : 132)
                }
            } label: {
                HStack {
                    Label("已配置规则", systemImage: "list.bullet.rectangle")
                    Spacer()
                    Text("\(model.enabledRuleCount)/\(model.rules.count) 条启用")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button("新建规则") { model.newRule() }
                Button("删除规则", role: .destructive) { showDeleteConfirmation = true }
                    .disabled(!model.canDelete || model.isBusy)
                Spacer()
                Button { model.refreshInterfaces() } label: {
                    Label("刷新网卡", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy)
            }

            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                    GridRow {
                        Text("目标地址").frame(width: 74, alignment: .leading)
                        TextField("域名或 IPv4 地址，不要填写协议、路径或端口", text: $model.target)
                            .font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("本地网卡").frame(width: 74, alignment: .leading)
                        Picker("本地网卡", selection: $model.interfaceName) {
                            if model.interfaces.isEmpty {
                                Text("正在读取网卡…").tag("")
                            }
                            ForEach(model.interfaces) { option in
                                Text("\(option.displayName) (\(option.device))").tag(option.device)
                            }
                            if !model.interfaceName.isEmpty,
                               !model.interfaces.contains(where: { $0.device == model.interfaceName }) {
                                Text("已保存的网卡 (\(model.interfaceName))").tag(model.interfaceName)
                            }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text("DNS").frame(width: 74, alignment: .leading)
                        TextField("留空则自动使用所选网卡 DNS", text: $model.dns)
                            .font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Color.clear.frame(width: 74, height: 1)
                        Toggle("启用当前规则", isOn: $model.isEnabled)
                            .toggleStyle(.checkbox)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .disabled(model.isBusy)
                .padding(4)
            } label: {
                Label(model.selectedRuleID == nil ? "新规则" : "规则设置",
                      systemImage: "slider.horizontal.3")
            }

            HStack(spacing: 10) {
                Button("恢复并卸载路由服务", role: .destructive) {
                    showRestoreConfirmation = true
                }
                .disabled(!model.routeServiceReady || model.isBusy)
                if !model.routeServiceReady {
                    Button("安装路由服务") { model.installOrUpdateService() }
                        .disabled(model.isBusy)
                }
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button("保存并应用") { model.saveAndApply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || model.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
        }
        .padding(embedded ? 12 : 20)
        .frame(maxWidth: .infinity, maxHeight: embedded ? .infinity : nil, alignment: .top)
        .frame(width: embedded ? nil : 650, height: embedded ? nil : 570, alignment: .top)
        .onAppear { model.activate() }
        .confirmationDialog("删除当前规则？", isPresented: $showDeleteConfirmation) {
            Button("删除", role: .destructive) { model.deleteSelectedRule() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("删除后，对应的主机路由和域名解析配置会由后台自动清理。")
        }
        .confirmationDialog("恢复系统路由并卸载服务？", isPresented: $showRestoreConfirmation) {
            Button("恢复并卸载", role: .destructive) { model.restoreAndUninstallService() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("这会删除本工具创建的主机路由和专用 DNS 配置，但保留规则文件。")
        }
    }
}
