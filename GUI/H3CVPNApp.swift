import SwiftUI
import AppKit
import Foundation
import Darwin

private let helperSocketPath = "/var/run/com.codex.h3cvpn.sock"
private let helperMagic: UInt32 = 0x48334356
private let helperVersion: UInt32 = 5
private let helperStart: UInt32 = 1
private let helperStop: UInt32 = 2
private let helperStatusCommand: UInt32 = 3
private let logTailReadLimit: UInt64 = 64 * 1024
private let maxConnectionLogBytes: UInt64 = 8 * 1024 * 1024
private let connectionEstablishmentTimeout: TimeInterval = 30

private enum PreferenceKey {
    static let rememberUsername = "rememberUsername"
    static let rememberPassword = "rememberPassword"
    static let username = "savedUsername"
    static let password = "savedPassword"
    static let allowTunnelRoute = "allowTunnelRoute"
    static let gatewayProfiles = "gatewayProfiles"
    static let selectedGateway = "selectedGateway"
    static let selectedLocalInterface = "selectedLocalInterface"
    static let lastLogPath = "lastLogPath"
}

struct GatewayProfile: Codable, Hashable, Identifiable {
    var id: String { address }
    let name: String
    let address: String
    let serverPin: String

    var displayName: String {
        name.isEmpty ? address : name
    }

    static let placeholder = GatewayProfile(name: "请配置网关", address: "", serverPin: "")
}

private struct CommandResult: Sendable {
    let status: Int32
    let output: String
}

private func runCommand(_ executable: String, _ arguments: [String]) throws -> CommandResult {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return CommandResult(status: process.terminationStatus,
                         output: String(data: data, encoding: .utf8) ?? "")
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

private func appleScriptLiteral(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
}

private func gatewayHost(_ gateway: String) -> String {
    if gateway.hasPrefix("[") {
        return gateway.split(separator: "]", maxSplits: 1).first.map { String($0.dropFirst()) } ?? gateway
    }
    return gateway.split(separator: ":", maxSplits: 1).first.map(String.init) ?? gateway
}

private func isValidGatewayAddress(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy {
        CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:-[]")
            .contains($0)
    }
}

private func isValidServerPin(_ value: String) -> Bool {
    value.hasPrefix("pin-sha256:") && value.count > 11 && value.utf8.count <= 256
}

private func probeServerPin(core: URL, gateway: String, localInterface: String) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = core
    process.arguments = ["--protocol=h3c", "--non-inter", "--authenticate", "--", gateway]
    var environment = ProcessInfo.processInfo.environment
    if localInterface.isEmpty {
        environment.removeValue(forKey: "H3CVPN_BOUND_INTERFACE")
    } else {
        environment["H3CVPN_BOUND_INTERFACE"] = localInterface
    }
    process.environment = environment
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()

    let deadline = Date().addingTimeInterval(15)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
    if process.isRunning { process.terminate() }
    process.waitUntilExit()

    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    for token in output.split(whereSeparator: { $0.isWhitespace }) {
        let value = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "'\".,;"))
        if value.hasPrefix("pin-sha256:"), value.count > 11, value.utf8.count <= 256 {
            return value
        }
    }
    if Date() >= deadline {
        throw NSError(domain: "H3CVPN", code: 40,
                      userInfo: [NSLocalizedDescriptionKey: "读取证书超时"])
    }
    throw NSError(domain: "H3CVPN", code: 41,
                  userInfo: [NSLocalizedDescriptionKey: "网关未返回可识别的证书指纹"])
}

@MainActor
private func applyBundledAppIcon() {
    guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
          let image = NSImage(contentsOf: url) else { return }
    NSApp.applicationIconImage = image
}

private func routeInterface(to gateway: String) -> String {
    guard let result = try? runCommand("/sbin/route", ["-n", "get", gatewayHost(gateway)]),
          result.status == 0 else { return "unknown" }
    for line in result.output.split(separator: "\n") {
        let value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("interface:") {
            return value.replacingOccurrences(of: "interface:", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
    }
    return "unknown"
}

private struct InterfaceTraffic: Sendable {
    let name: String
    let receivedBytes: UInt64
    let sentBytes: UInt64
}

struct LocalInterfaceOption: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let address: String

    var displayName: String { "\(name) · \(address)" }
}

private func availableLocalInterfaces() -> [LocalInterfaceOption] {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return [] }
    defer { freeifaddrs(first) }

    var interfaces: [String: LocalInterfaceOption] = [:]
    var pointer: UnsafeMutablePointer<ifaddrs>? = first
    while let current = pointer {
        let item = current.pointee
        let flags = item.ifa_flags
        if let address = item.ifa_addr,
           address.pointee.sa_family == UInt8(AF_INET),
           flags & UInt32(IFF_UP) != 0,
           flags & UInt32(IFF_RUNNING) != 0,
           flags & UInt32(IFF_LOOPBACK) == 0,
           flags & UInt32(IFF_POINTOPOINT) == 0 {
            let name = String(cString: item.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = host.withUnsafeMutableBufferPointer { buffer in
                getnameinfo(address, socklen_t(address.pointee.sa_len), buffer.baseAddress,
                            socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
            }
            if result == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("127."), !ip.hasPrefix("169.254.") {
                    interfaces[name] = LocalInterfaceOption(name: name, address: ip)
                }
            }
        }
        pointer = item.ifa_next
    }
    return interfaces.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

private func configuredVPNAddress(from log: String) -> String? {
    for line in log.split(separator: "\n").reversed() {
        guard let marker = line.range(of: "Configured as ") else { continue }
        let suffix = line[marker.upperBound...]
        let address = suffix.prefix { $0.isNumber || $0 == "." }
        if !address.isEmpty { return String(address) }
    }
    return nil
}

private struct ConnectionLogSnapshot {
    let text: String
    let size: UInt64
}

private func connectionLogSnapshot(at url: URL) throws -> ConnectionLogSnapshot {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    try handle.seek(toOffset: size > logTailReadLimit ? size - logTailReadLimit : 0)
    let data = try handle.read(upToCount: Int(logTailReadLimit)) ?? Data()
    return ConnectionLogSnapshot(text: String(decoding: data, as: UTF8.self), size: size)
}

private func connectionFailureMessage(from log: String) -> String? {
    if log.contains("Login error:") || log.contains("Failed to complete authentication") {
        return "认证失败，请检查用户名、密码、认证服务器或账号在线人数限制"
    }
    if log.contains("SSL connection failure") {
        return "SSL 连接失败"
    }
    if log.contains("Read error on TLS session") {
        return "VPN TLS 通道已关闭"
    }
    if log.contains("Failed to connect to host") {
        return "无法连接 VPN 网关"
    }
    if log.contains("Script '") && log.contains("returned error") {
        return "VPN 网络配置失败"
    }
    return nil
}

private func interfaceTraffic(forIPv4 targetAddress: String) -> InterfaceTraffic? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(first) }

    var targetName: String?
    var pointer: UnsafeMutablePointer<ifaddrs>? = first
    while let current = pointer {
        let item = current.pointee
        if let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = host.withUnsafeMutableBufferPointer { buffer in
                getnameinfo(address, socklen_t(address.pointee.sa_len), buffer.baseAddress,
                            socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
            }
            if result == 0, String(cString: host) == targetAddress {
                let name = String(cString: item.ifa_name)
                if name.hasPrefix("utun") {
                    targetName = name
                    break
                }
            }
        }
        pointer = item.ifa_next
    }

    guard let targetName else { return nil }
    pointer = first
    while let current = pointer {
        let item = current.pointee
        if String(cString: item.ifa_name) == targetName, let rawData = item.ifa_data {
            let data = rawData.assumingMemoryBound(to: if_data.self).pointee
            return InterfaceTraffic(name: targetName,
                                    receivedBytes: UInt64(data.ifi_ibytes),
                                    sentBytes: UInt64(data.ifi_obytes))
        }
        pointer = item.ifa_next
    }
    return nil
}

private func formattedBytes(_ value: UInt64) -> String {
    if value == 0 { return "0 B" }
    let formatter = ByteCountFormatter()
    formatter.countStyle = .binary
    formatter.includesUnit = true
    formatter.includesCount = true
    return formatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))))
}

private struct HelperResponse: Sendable {
    let status: Int32
    let pid: pid_t
    let message: String
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

private func writeAll(_ fd: Int32, data: Data) throws {
    try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < raw.count {
            let count = write(fd, base.advanced(by: offset), raw.count - offset)
            if count < 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { throw POSIXError(.EPIPE) }
            offset += count
        }
    }
}

private func readExact(_ fd: Int32, count: Int) throws -> Data {
    var result = Data()
    result.reserveCapacity(count)
    while result.count < count {
        var buffer = [UInt8](repeating: 0, count: count - result.count)
        let n = read(fd, &buffer, buffer.count)
        if n < 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if n == 0 { throw POSIXError(.ECONNRESET) }
        result.append(buffer, count: n)
    }
    return result
}

private func readUInt32(_ data: Data, offset: Int) -> UInt32 {
    let bytes = [UInt8](data[offset..<(offset + 4)])
    return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
}

private func helperRequest(command: UInt32, fields: [String]) throws -> HelperResponse {
    guard fields.count == 6 else { throw POSIXError(.EINVAL) }
    var request = Data()
    [helperMagic, helperVersion, command].forEach { appendUInt32($0, to: &request) }
    fields.forEach { appendUInt32(UInt32($0.utf8.count), to: &request) }
    fields.forEach { request.append(contentsOf: $0.utf8) }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 15, tv_usec: 0)
    let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
    guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize) == 0,
          setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(helperSocketPath.utf8) + [0]
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: pathBytes)
    }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED) }
    try writeAll(fd, data: request)
    let response = try readExact(fd, count: 12)
    let status = Int32(bitPattern: readUInt32(response, offset: 0))
    let pid = pid_t(readUInt32(response, offset: 4))
    let messageLength = Int(readUInt32(response, offset: 8))
    let messageData = messageLength > 0 ? try readExact(fd, count: messageLength) : Data()
    return HelperResponse(status: status, pid: pid,
                          message: String(data: messageData, encoding: .utf8) ?? "")
}

@MainActor
final class VPNViewModel: ObservableObject {
    @Published var gatewayProfiles: [GatewayProfile]
    @Published var gateway: String
    @Published var username: String
    @Published var password: String
    @Published var rememberUsername: Bool
    @Published var rememberPassword: Bool
    @Published var allowTunnelRoute: Bool
    @Published var localInterfaces: [LocalInterfaceOption]
    @Published var selectedLocalInterface: String
    @Published var routeName = "正在检查…"
    @Published var statusText = "尚未连接"
    @Published var logText = "等待操作…"
    @Published var helperStatus = "正在检查后台服务…"
    @Published var helperInstalled = false
    @Published var helperNeedsUpdate = false
    @Published var isBusy = false
    @Published var isConnected = false
    @Published var downloadBytes: UInt64 = 0
    @Published var uploadBytes: UInt64 = 0
    @Published var downloadBytesPerSecond: UInt64 = 0
    @Published var uploadBytesPerSecond: UInt64 = 0
    @Published var trafficInterface = ""

    private var vpnPID: pid_t?
    private var logURL: URL?
    private var timer: Timer?
    private var connectionStartedAt: Date?
    private var connectionEstablished = false
    private var vpnAddress: String?
    private var isRefreshingState = false
    private var lastTrafficSample: (date: Date, received: UInt64, sent: UInt64, interface: String)?
    private let defaults = UserDefaults.standard

    init() {
        let storedProfiles: [GatewayProfile]
        if let data = defaults.data(forKey: PreferenceKey.gatewayProfiles),
           let decoded = try? JSONDecoder().decode([GatewayProfile].self, from: data),
           !decoded.isEmpty {
            storedProfiles = decoded
        } else {
            storedProfiles = [.placeholder]
        }
        gatewayProfiles = storedProfiles
        let storedGateway = defaults.string(forKey: PreferenceKey.selectedGateway)
        gateway = storedProfiles.contains(where: { $0.address == storedGateway })
            ? storedGateway! : storedProfiles[0].address
        let shouldRememberUsername = defaults.bool(forKey: PreferenceKey.rememberUsername)
        let shouldRememberPassword = defaults.bool(forKey: PreferenceKey.rememberPassword)
        rememberUsername = shouldRememberUsername
        rememberPassword = shouldRememberPassword
        username = shouldRememberUsername ? defaults.string(forKey: PreferenceKey.username) ?? "" : ""
        password = shouldRememberPassword ? defaults.string(forKey: PreferenceKey.password) ?? "" : ""
        allowTunnelRoute = defaults.bool(forKey: PreferenceKey.allowTunnelRoute)
        let interfaces = availableLocalInterfaces()
        localInterfaces = interfaces
        let savedInterface = defaults.string(forKey: PreferenceKey.selectedLocalInterface) ?? ""
        selectedLocalInterface = interfaces.contains(where: { $0.name == savedInterface })
            ? savedInterface : ""
        if let savedLogPath = defaults.string(forKey: PreferenceKey.lastLogPath) {
            logURL = URL(fileURLWithPath: savedLogPath)
        }
    }

    var routeIsTunnel: Bool { routeName.hasPrefix("utun") }
    var usesExplicitLocalInterface: Bool { !selectedLocalInterface.isEmpty }
    var selectedProfile: GatewayProfile {
        gatewayProfiles.first(where: { $0.address == gateway }) ?? .placeholder
    }
    var canRemoveGateway: Bool { !gateway.isEmpty }
    var downloadRateText: String { "\(formattedBytes(downloadBytesPerSecond))/s" }
    var uploadRateText: String { "\(formattedBytes(uploadBytesPerSecond))/s" }
    var downloadTotalText: String { formattedBytes(downloadBytes) }
    var uploadTotalText: String { formattedBytes(uploadBytes) }
    var hasLog: Bool { logURL != nil }

    func checkRoute() {
        let target = gateway.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidGatewayAddress(target) else {
            routeName = "未配置"
            if !isConnected { statusText = "请先添加 VPN 网关" }
            checkHelper()
            return
        }
        if let selected = localInterfaces.first(where: { $0.name == selectedLocalInterface }) {
            routeName = selected.displayName
            if !isConnected { statusText = "将通过 \(selected.name) 连接 VPN 网关" }
            checkHelper()
            return
        }
        if allowTunnelRoute {
            routeName = "已跳过"
            if !isConnected { statusText = "已允许通过现有 utun 连接" }
            checkHelper()
            return
        }
        routeName = "正在检查…"
        Task {
            let route = await Task.detached { routeInterface(to: target) }.value
            routeName = route
            if route.hasPrefix("utun") {
                statusText = "网关流量正经过 \(route)，请先关闭 Shadowrocket"
            } else if route == "unknown" {
                statusText = "无法读取网关路由"
            } else if !isConnected {
                statusText = "网络路径可用，可以连接"
            }
        }
        checkHelper()
    }

    func selectLocalInterface(_ name: String) {
        guard name.isEmpty || localInterfaces.contains(where: { $0.name == name }) else { return }
        selectedLocalInterface = name
        if name.isEmpty {
            defaults.removeObject(forKey: PreferenceKey.selectedLocalInterface)
        } else {
            defaults.set(name, forKey: PreferenceKey.selectedLocalInterface)
        }
        checkRoute()
    }

    func refreshLocalInterfaces() {
        localInterfaces = availableLocalInterfaces()
        if !selectedLocalInterface.isEmpty,
           !localInterfaces.contains(where: { $0.name == selectedLocalInterface }) {
            selectedLocalInterface = ""
            defaults.removeObject(forKey: PreferenceKey.selectedLocalInterface)
        }
        checkRoute()
    }

    func setAllowTunnelRoute(_ enabled: Bool) {
        allowTunnelRoute = enabled
        defaults.set(enabled, forKey: PreferenceKey.allowTunnelRoute)
        checkRoute()
    }

    func setRememberUsername(_ enabled: Bool) {
        rememberUsername = enabled
        defaults.set(enabled, forKey: PreferenceKey.rememberUsername)
        if enabled {
            defaults.set(username, forKey: PreferenceKey.username)
        } else {
            defaults.removeObject(forKey: PreferenceKey.username)
            if rememberPassword { setRememberPassword(false) }
        }
    }

    func setRememberPassword(_ enabled: Bool) {
        rememberPassword = enabled
        defaults.set(enabled, forKey: PreferenceKey.rememberPassword)
        if enabled {
            if !rememberUsername { setRememberUsername(true) }
            if !password.isEmpty { defaults.set(password, forKey: PreferenceKey.password) }
        } else {
            defaults.removeObject(forKey: PreferenceKey.password)
        }
    }

    func selectGateway(_ address: String) {
        guard gatewayProfiles.contains(where: { $0.address == address }) else { return }
        gateway = address
        defaults.set(address, forKey: PreferenceKey.selectedGateway)
        checkRoute()
    }

    func saveGateway(name: String, address: String, serverPin: String) -> String? {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedPin = serverPin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidGatewayAddress(cleanedAddress) else { return "网关地址格式不正确" }
        guard isValidServerPin(cleanedPin) else {
            return "请输入 pin-sha256 格式的证书指纹"
        }
        let profile = GatewayProfile(name: cleanedName, address: cleanedAddress, serverPin: cleanedPin)
        if gatewayProfiles.count == 1, gatewayProfiles[0].address.isEmpty {
            gatewayProfiles[0] = profile
        } else if let index = gatewayProfiles.firstIndex(where: { $0.address == cleanedAddress }) {
            gatewayProfiles[index] = profile
        } else {
            gatewayProfiles.append(profile)
        }
        persistGateways()
        selectGateway(cleanedAddress)
        return nil
    }

    func detectServerPin(address: String, localInterface: String) async throws -> String {
        let cleanedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidGatewayAddress(cleanedAddress) else {
            throw NSError(domain: "H3CVPN", code: 42,
                          userInfo: [NSLocalizedDescriptionKey: "请先输入有效的网关地址"])
        }
        guard let core = Bundle.main.url(forResource: "openconnect", withExtension: nil) else {
            throw NSError(domain: "H3CVPN", code: 43,
                          userInfo: [NSLocalizedDescriptionKey: "安装包缺少连接核心"])
        }
        guard localInterface.isEmpty || localInterfaces.contains(where: { $0.name == localInterface }) else {
            throw NSError(domain: "H3CVPN", code: 44,
                          userInfo: [NSLocalizedDescriptionKey: "所选探测网口已不可用，请重新选择"])
        }
        return try await Task.detached {
            try probeServerPin(core: core, gateway: cleanedAddress, localInterface: localInterface)
        }.value
    }

    func removeSelectedGateway() {
        guard canRemoveGateway else { return }
        gatewayProfiles.removeAll { $0.address == gateway }
        if gatewayProfiles.isEmpty { gatewayProfiles = [.placeholder] }
        persistGateways()
        selectGateway(gatewayProfiles[0].address)
    }

    private func persistGateways() {
        if let data = try? JSONEncoder().encode(gatewayProfiles) {
            defaults.set(data, forKey: PreferenceKey.gatewayProfiles)
        }
    }

    func checkHelper() {
        Task {
            let response = await Task.detached {
                try? helperRequest(command: helperStatusCommand,
                                   fields: ["", "", "", "", "", ""])
            }.value
            let responseStatus = response?.status
            let available = responseStatus == 0 || responseStatus == 1
            helperInstalled = available
            helperNeedsUpdate = responseStatus == -11
            if available {
                helperStatus = "后台服务已安装，后续连接无需重复授权"
            } else if helperNeedsUpdate {
                helperStatus = "后台服务版本过旧，请点击更新服务"
            } else {
                helperStatus = "未安装后台服务，需要管理员授权一次"
            }
            if !available && !isConnected {
                statusText = helperNeedsUpdate ? "请先更新后台服务" : "请先安装后台服务"
            } else if responseStatus == 0, let pid = response?.pid, pid > 0, !isConnected {
                vpnPID = pid
                isConnected = true
                statusText = "VPN 正在后台运行"
                startMonitoring()
            }
        }
    }

    func installHelper() {
        guard let helper = Bundle.main.url(forResource: "com.codex.h3cvpn.helper", withExtension: nil),
              let plist = Bundle.main.url(forResource: "com.codex.h3cvpn.helper", withExtension: "plist"),
              let core = Bundle.main.url(forResource: "openconnect", withExtension: nil),
              let script = Bundle.main.url(forResource: "vpnc-script", withExtension: nil),
              let crypto = Bundle.main.url(forResource: "libcrypto.3.dylib", withExtension: nil),
              let ssl = Bundle.main.url(forResource: "libssl.3.dylib", withExtension: nil),
              let xml = Bundle.main.url(forResource: "libxml2.16.dylib", withExtension: nil),
              let lz4 = Bundle.main.url(forResource: "liblz4.1.dylib", withExtension: nil),
              let openconnectLib = Bundle.main.url(forResource: "libopenconnect.5.dylib", withExtension: nil) else {
            helperStatus = "安装包不完整：缺少后台服务资源"
            return
        }
        isBusy = true
        helperStatus = "等待一次性管理员授权…"
        let paths = [helper.path, plist.path, core.path, script.path, crypto.path, ssl.path,
                     xml.path, lz4.path, openconnectLib.path]
        Task {
            do {
                let result = try await Task.detached {
                    try Self.installPrivileged(resources: paths)
                }.value
                helperInstalled = true
                helperNeedsUpdate = false
                helperStatus = result
                isBusy = false
                statusText = "后台服务已就绪，后续连接不再弹授权"
            } catch {
                isBusy = false
                helperInstalled = false
                helperStatus = "安装失败：\(error.localizedDescription)"
                statusText = "后台服务安装失败，请查看连接日志"
                logText = helperStatus
            }
        }
    }

    nonisolated private static func installPrivileged(resources: [String]) throws -> String {
        // OpenConnect passes the script path through /bin/sh without shell quoting.
        // Keep privileged runtime resources in a path without spaces.
        let resourceDirectory = "/Library/H3CVPN/Resources"
        let ownerPath = "/Library/H3CVPN/owner.uid"
        let helperDestination = "/Library/PrivilegedHelperTools/com.codex.h3cvpn.helper"
        let plistDestination = "/Library/LaunchDaemons/com.codex.h3cvpn.helper.plist"
        let resourceNames = ["com.codex.h3cvpn.helper", "com.codex.h3cvpn.helper.plist", "openconnect",
                             "vpnc-script", "libcrypto.3.dylib", "libssl.3.dylib", "libxml2.16.dylib",
                             "liblz4.1.dylib", "libopenconnect.5.dylib"]
        let ownerUID = String(getuid())
        var commands = ["/bin/mkdir -p \(shellQuote(resourceDirectory))",
                        "( /bin/launchctl bootout system/com.codex.h3cvpn.helper >/dev/null 2>&1 || true )",
                        "/usr/bin/printf %s \(shellQuote(ownerUID)) > \(shellQuote(ownerPath))",
                        "/bin/cp -f \(shellQuote(resources[0])) \(shellQuote(helperDestination))",
                        "/bin/cp -f \(shellQuote(resources[1])) \(shellQuote(plistDestination))"]
        for index in 2..<resources.count {
            commands.append("/bin/cp -f \(shellQuote(resources[index])) \(shellQuote(resourceDirectory + "/" + resourceNames[index]))")
        }
        commands += [
            "/usr/bin/xattr -cr \(shellQuote(resourceDirectory)) \(shellQuote(helperDestination)) \(shellQuote(plistDestination))",
            "/usr/sbin/chown -R root:wheel \(shellQuote(resourceDirectory)) \(shellQuote(ownerPath)) \(shellQuote(helperDestination)) \(shellQuote(plistDestination))",
            "/bin/chmod 644 \(shellQuote(ownerPath))",
            "/bin/chmod 755 \(shellQuote(helperDestination)) \(shellQuote(resourceDirectory + "/openconnect")) \(shellQuote(resourceDirectory + "/vpnc-script"))",
            "/bin/chmod 644 \(shellQuote(plistDestination)) \(shellQuote(resourceDirectory + "/libcrypto.3.dylib")) \(shellQuote(resourceDirectory + "/libssl.3.dylib")) \(shellQuote(resourceDirectory + "/libxml2.16.dylib")) \(shellQuote(resourceDirectory + "/liblz4.1.dylib")) \(shellQuote(resourceDirectory + "/libopenconnect.5.dylib"))",
            "/usr/bin/plutil -lint \(shellQuote(plistDestination)) >/dev/null",
            "/bin/launchctl enable system/com.codex.h3cvpn.helper",
            "( /bin/launchctl bootstrap system \(shellQuote(plistDestination)) || { /bin/sleep 1; /bin/launchctl bootstrap system \(shellQuote(plistDestination)); } )"
        ]
        let command = commands.joined(separator: " && ")
        let source = "do shell script \(appleScriptLiteral(command)) with administrator privileges"
        let result = try runCommand("/usr/bin/osascript", ["-e", source])
        guard result.status == 0 else {
            throw NSError(domain: "H3CVPN", code: 30,
                          userInfo: [NSLocalizedDescriptionKey: result.output.isEmpty ? "管理员授权被取消" : result.output])
        }
        for _ in 0..<20 {
            if let response = try? helperRequest(command: helperStatusCommand,
                                                 fields: ["", "", "", "", "", ""]),
               response.status == 0 || response.status == 1 {
                return "后台服务安装成功"
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw NSError(domain: "H3CVPN", code: 31,
                      userInfo: [NSLocalizedDescriptionKey: "服务已安装但未能启动"])
    }

    func connect() {
        guard !isBusy, !isConnected else { return }
        logText = ""
        let suppliedGateway = gateway.trimmingCharacters(in: .whitespacesAndNewlines)
        let suppliedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let suppliedInterface = selectedLocalInterface
        guard isValidGatewayAddress(suppliedGateway) else {
            statusText = "请先添加有效的 VPN 网关"
            logText = statusText
            return
        }
        guard !suppliedUsername.isEmpty else {
            statusText = "请输入用户名"
            logText = statusText
            return
        }
        guard !password.isEmpty else {
            statusText = "请输入密码"
            logText = statusText
            return
        }
        guard helperInstalled else {
            statusText = "请先安装后台服务；只需授权一次"
            logText = statusText
            return
        }
        if !suppliedInterface.isEmpty,
           !localInterfaces.contains(where: { $0.name == suppliedInterface }) {
            statusText = "所选本地网口已不可用，请重新选择"
            logText = statusText
            refreshLocalInterfaces()
            return
        }
        if suppliedInterface.isEmpty && routeIsTunnel && !allowTunnelRoute {
            statusText = "已阻止连接：请先关闭 Shadowrocket 或其他 VPN"
            logText = statusText
            return
        }
        isBusy = true
        statusText = "正在启动兼容 H3C 的 SSL VPN…"
        let suppliedPassword = password
        let suppliedPin = selectedProfile.serverPin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidServerPin(suppliedPin) else {
            isBusy = false
            statusText = "当前网关缺少有效的证书指纹，请编辑网关后自动获取"
            logText = statusText
            return
        }
        if rememberUsername {
            defaults.set(suppliedUsername, forKey: PreferenceKey.username)
        }
        if rememberPassword {
            defaults.set(suppliedPassword, forKey: PreferenceKey.password)
        }
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("H3CVPN-\(UUID().uuidString)", isDirectory: true)
        let log = directory.appendingPathComponent("connection.log")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            FileManager.default.createFile(atPath: log.path, contents: Data(),
                                           attributes: [.posixPermissions: 0o600])
        } catch {
            isBusy = false
            statusText = "无法创建连接日志：\(error.localizedDescription)"
            logText = statusText
            return
        }
        logURL = log
        vpnAddress = nil
        logText = suppliedInterface.isEmpty
            ? "正在自动选择网口连接 \(suppliedGateway)…"
            : "正在通过 \(suppliedInterface) 连接 \(suppliedGateway)…"
        resetTraffic()
        startMonitoring()

        Task {
            do {
                let result = try await Task.detached {
                    try helperRequest(command: helperStart,
                                      fields: [suppliedGateway, suppliedUsername, suppliedPassword,
                                               suppliedPin, log.path, suppliedInterface])
                }.value
                guard result.status == 0 else {
                    throw NSError(domain: "H3CVPN", code: Int(result.status),
                                  userInfo: [NSLocalizedDescriptionKey: result.message])
                }
                vpnPID = result.pid
                defaults.set(log.path, forKey: PreferenceKey.lastLogPath)
                isConnected = true
                isBusy = false
                connectionStartedAt = Date()
                connectionEstablished = false
                statusText = "正在认证并获取 VPN 配置…"
                startMonitoring()
            } catch {
                timer?.invalidate()
                timer = nil
                isBusy = false
                statusText = "连接未启动：\(error.localizedDescription)"
                if let snapshot = try? connectionLogSnapshot(at: log), !snapshot.text.isEmpty {
                    logText = "\(snapshot.text)\n\(statusText)"
                } else {
                    logText = statusText
                }
            }
        }
    }

    func disconnect() {
        guard let pid = vpnPID else { return }
        stopConnection(pid: pid, progressMessage: "正在断开连接…", finalMessage: "已断开")
    }

    private func stopConnection(pid: pid_t, progressMessage: String, finalMessage: String) {
        guard vpnPID == pid, !isBusy else { return }
        isBusy = true
        statusText = progressMessage
        Task {
            let result = await Task.detached {
                try? helperRequest(command: helperStop, fields: [String(pid), "", "", "", "", ""])
            }.value
            guard vpnPID == pid else { return }
            isBusy = false
            if result?.status == 0 || result?.status == -17 {
                finishDisconnected(message: finalMessage)
            } else {
                statusText = result?.message ?? "断开失败"
            }
        }
    }

    func revealLog() {
        guard let logURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }

    private func startMonitoring() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshState() }
        }
        refreshState()
    }

    private func refreshState() {
        var failureMessage: String?
        var hasVPNAddress = false
        if let logURL, let snapshot = try? connectionLogSnapshot(at: logURL), !snapshot.text.isEmpty {
            logText = String(snapshot.text.suffix(12_000))
            failureMessage = connectionFailureMessage(from: snapshot.text)
            if snapshot.size >= maxConnectionLogBytes, failureMessage == nil {
                failureMessage = "连接日志达到 8 MB 上限，已自动停止异常连接"
            }
            if let address = configuredVPNAddress(from: snapshot.text) {
                vpnAddress = address
                hasVPNAddress = true
                if !connectionEstablished {
                    connectionEstablished = true
                    statusText = "已连接，VPN 地址 \(address)"
                }
                updateTraffic(for: address)
            } else if let vpnAddress {
                hasVPNAddress = true
                updateTraffic(for: vpnAddress)
            }
        }
        guard let pid = vpnPID else { return }

        if let failureMessage, isConnected, !isBusy {
            stopConnection(pid: pid,
                           progressMessage: "检测到连接错误，正在清理…",
                           finalMessage: failureMessage)
            return
        }
        if !hasVPNAddress, !connectionEstablished, !isBusy,
           let connectionStartedAt,
           Date().timeIntervalSince(connectionStartedAt) >= connectionEstablishmentTimeout {
            logText += "\n连接建立超过 30 秒，已自动停止。"
            stopConnection(pid: pid,
                           progressMessage: "连接超时，正在停止…",
                           finalMessage: "连接超时，未能获取 VPN 配置")
            return
        }
        guard !isRefreshingState, !isBusy else { return }
        isRefreshingState = true
        Task {
            let response = await Task.detached {
                try? helperRequest(command: helperStatusCommand, fields: ["", "", "", "", "", ""])
            }.value
            isRefreshingState = false
            guard vpnPID == pid, isConnected, !isBusy else { return }
            if response?.status == 1 {
                finishDisconnected(message: failureMessage ?? "连接进程已结束，请查看日志")
            } else if response == nil {
                statusText = "后台服务状态查询失败，正在重试…"
            }
        }
    }

    private func updateTraffic(for address: String) {
        guard let traffic = interfaceTraffic(forIPv4: address) else { return }
        let now = Date()
        if let previous = lastTrafficSample,
           previous.interface == traffic.name {
            let elapsed = now.timeIntervalSince(previous.date)
            if elapsed > 0 {
                let receivedDelta = traffic.receivedBytes >= previous.received
                    ? traffic.receivedBytes - previous.received : 0
                let sentDelta = traffic.sentBytes >= previous.sent
                    ? traffic.sentBytes - previous.sent : 0
                downloadBytesPerSecond = UInt64(Double(receivedDelta) / elapsed)
                uploadBytesPerSecond = UInt64(Double(sentDelta) / elapsed)
            }
        } else {
            downloadBytesPerSecond = 0
            uploadBytesPerSecond = 0
        }
        trafficInterface = traffic.name
        downloadBytes = traffic.receivedBytes
        uploadBytes = traffic.sentBytes
        lastTrafficSample = (now, traffic.receivedBytes, traffic.sentBytes, traffic.name)
    }

    private func resetTraffic() {
        downloadBytes = 0
        uploadBytes = 0
        downloadBytesPerSecond = 0
        uploadBytesPerSecond = 0
        trafficInterface = ""
        lastTrafficSample = nil
    }

    private func finishDisconnected(message: String) {
        timer?.invalidate()
        timer = nil
        vpnPID = nil
        isConnected = false
        isBusy = false
        connectionStartedAt = nil
        connectionEstablished = false
        vpnAddress = nil
        isRefreshingState = false
        defaults.removeObject(forKey: PreferenceKey.lastLogPath)
        resetTraffic()
        statusText = message
    }
}

struct ContentView: View {
    @ObservedObject var model: VPNViewModel
    @State private var gatewayDraft: GatewayProfile?

    private var routeColor: Color {
        if model.usesExplicitLocalInterface { return .blue }
        if model.allowTunnelRoute { return .blue }
        if model.routeName == "正在检查…" || model.routeName == "unknown" { return .orange }
        return model.routeIsTunnel ? .red : .green
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                connectionCard
                routeCard
                helperCard
                actionArea
                trafficCard
                logCard
                Text("实验客户端 · 凭据仅保存在本机 · 兼容 H3C TLS VPN")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
        }
        .frame(width: 500, height: 780, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            applyBundledAppIcon()
            model.checkRoute()
        }
        .sheet(item: $gatewayDraft) { profile in
            GatewayEditorView(
                profile: profile,
                localInterfaces: model.localInterfaces,
                selectedLocalInterface: model.selectedLocalInterface,
                onSelectLocalInterface: { model.selectLocalInterface($0) },
                probePin: { address, localInterface in
                    try await model.detectServerPin(address: address, localInterface: localInterface)
                },
                onSave: { name, address, pin in
                    model.saveGateway(name: name, address: address, serverPin: pin)
                }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(0.18))
                if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                   let icon = NSImage(contentsOf: url) {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .padding(3)
                } else {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text("SSL VPN Connect")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                Text("macOS 安全接入客户端")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.82))
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(model.isConnected ? .green : .white.opacity(0.45))
                    .frame(width: 8, height: 8)
                Text(model.isConnected ? "已启动" : "未连接")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.16), in: Capsule())
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .background(LinearGradient(colors: [Color(red: 0.08, green: 0.38, blue: 0.84),
                                             Color(red: 0.12, green: 0.62, blue: 0.86)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var connectionCard: some View {
        GroupBox {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Text("VPN 网关")
                        .frame(width: 72, alignment: .leading)
                    HStack(spacing: 6) {
                        Picker("VPN 网关", selection: Binding(
                            get: { model.gateway },
                            set: { model.selectGateway($0) }
                        )) {
                            ForEach(model.gatewayProfiles) { profile in
                                Text(profile.displayName).tag(profile.address)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130, alignment: .leading)
                        .help(model.gateway)

                        Button { gatewayDraft = GatewayProfile(name: "", address: "", serverPin: "") } label: {
                            Image(systemName: "plus")
                        }
                        .help("添加网关")

                        Button { gatewayDraft = model.selectedProfile } label: {
                            Image(systemName: "pencil")
                        }
                        .help("编辑当前网关")

                        Button { model.removeSelectedGateway() } label: {
                            Image(systemName: "minus")
                        }
                        .help("删除当前网关")
                        .disabled(!model.canRemoveGateway)
                    }
                    .disabled(model.isConnected)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    Text("用户名")
                        .frame(width: 72, alignment: .leading)
                    TextField("请输入用户名", text: $model.username)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                        .disabled(model.isConnected)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    Text("密码")
                        .frame(width: 72, alignment: .leading)
                    SecureField(model.rememberPassword ? "保存在本机配置" : "仅保存在内存中",
                                text: $model.password)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                        .disabled(model.isConnected)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    Color.clear.frame(width: 72, height: 1)
                    HStack(spacing: 22) {
                        Toggle("记住用户名", isOn: Binding(
                            get: { model.rememberUsername },
                            set: { model.setRememberUsername($0) }
                        ))
                        Toggle("记住密码", isOn: Binding(
                            get: { model.rememberPassword },
                            set: { model.setRememberPassword($0) }
                        ))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.checkbox)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(model.isConnected)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("连接信息", systemImage: "person.badge.key.fill")
                .font(.headline)
        }
    }

    private var routeCard: some View {
        GroupBox {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Circle().fill(routeColor).frame(width: 10, height: 10)
                    Text("网关出口")
                        .frame(width: 64, alignment: .leading)
                    Picker("网关出口", selection: Binding(
                        get: { model.selectedLocalInterface },
                        set: { model.selectLocalInterface($0) }
                    )) {
                        Text("自动选择 · \(model.usesExplicitLocalInterface ? "系统路由" : model.routeName)")
                            .tag("")
                        ForEach(model.localInterfaces) { item in
                            Text(item.displayName).tag(item.name)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .disabled(model.isConnected)
                    Button { model.refreshLocalInterfaces() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("刷新本地网口")
                    .disabled(model.isConnected)
                }
                if model.usesExplicitLocalInterface {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "network").foregroundStyle(.blue)
                        Text("已绑定 \(model.routeName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else if model.allowTunnelRoute {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(.blue)
                        Text("当前连接允许沿系统现有 utun 路径发送，不执行网关出口检查。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else if model.routeIsTunnel {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text("检测到现有 VPN/代理隧道。建议先关闭 Shadowrocket，否则 H3C TLS 握手可能失败。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                Toggle("仍允许经过现有 utun 隧道连接", isOn: Binding(
                    get: { model.allowTunnelRoute },
                    set: { model.setAllowTunnelRoute($0) }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(model.isConnected || model.usesExplicitLocalInterface)
            }
            .padding(6)
        } label: {
            Label("网络路径", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
        }
    }

    private var actionArea: some View {
        VStack(spacing: 6) {
            Button {
                model.isConnected ? model.disconnect() : model.connect()
            } label: {
                HStack {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Image(systemName: model.isConnected ? "stop.fill" : "bolt.fill")
                    Text(model.isConnected ? "断开连接" : "连接 SSL VPN")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isConnected ? .red : .blue)
            .controlSize(.large)
            .disabled(model.isBusy)

            Text(model.statusText)
                .font(.callout)
                .foregroundStyle(model.routeIsTunnel && !model.allowTunnelRoute ? .red : .secondary)
                .frame(maxWidth: .infinity)
        }
    }

    private var helperCard: some View {
        GroupBox {
            HStack(spacing: 10) {
                Image(systemName: model.helperInstalled ? "checkmark.shield.fill" : "lock.shield")
                    .foregroundStyle(model.helperInstalled ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.helperInstalled ? "后台服务已安装" :
                         (model.helperNeedsUpdate ? "后台服务需要更新" : "需要安装后台服务"))
                        .font(.subheadline.weight(.medium))
                    Text(model.helperStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(model.helperStatus)
                }
                Spacer()
                Button(model.helperInstalled || model.helperNeedsUpdate ? "更新服务" : "安装服务") {
                    model.installHelper()
                }
                .disabled(model.isBusy || model.isConnected)
            }
            .padding(6)
        } label: {
            Label("授权方式", systemImage: "person.badge.shield.checkmark")
                .font(.headline)
        }
    }

    private var trafficCard: some View {
        GroupBox {
            HStack(spacing: 18) {
                trafficMetric(title: "下载",
                              systemImage: "arrow.down",
                              color: .green,
                              rate: model.downloadRateText,
                              total: model.downloadTotalText)
                Divider().frame(height: 44)
                trafficMetric(title: "上传",
                              systemImage: "arrow.up",
                              color: .blue,
                              rate: model.uploadRateText,
                              total: model.uploadTotalText)
            }
            .padding(6)
            .frame(height: 56)
        } label: {
            HStack {
                Label("流量统计", systemImage: "waveform.path.ecg")
                    .font(.headline)
                Spacer()
                Text(model.trafficInterface.isEmpty ? "等待 VPN 接口" : model.trafficInterface)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func trafficMetric(title: String, systemImage: String, color: Color,
                               rate: String, total: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title)  \(rate)")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                Text("本次累计 \(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var logCard: some View {
        GroupBox {
            ScrollView {
                Text(model.logText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
            }
            .scrollIndicators(.hidden)
            .frame(height: 84)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        } label: {
            HStack {
                Label("连接日志", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Spacer()
                Button("在访达中显示") { model.revealLog() }
                    .buttonStyle(.link)
                    .disabled(!model.hasLog)
            }
        }
    }
}

private struct GatewayEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var address: String
    @State private var serverPin: String
    @State private var selectedLocalInterface: String
    @State private var errorMessage = ""
    @State private var isProbing = false
    let localInterfaces: [LocalInterfaceOption]
    let onSelectLocalInterface: (String) -> Void
    let probePin: (String, String) async throws -> String
    let onSave: (String, String, String) -> String?

    init(profile: GatewayProfile,
         localInterfaces: [LocalInterfaceOption],
         selectedLocalInterface: String,
         onSelectLocalInterface: @escaping (String) -> Void,
         probePin: @escaping (String, String) async throws -> String,
         onSave: @escaping (String, String, String) -> String?) {
        _name = State(initialValue: profile.name)
        _address = State(initialValue: profile.address)
        _serverPin = State(initialValue: profile.serverPin)
        _selectedLocalInterface = State(initialValue: selectedLocalInterface)
        self.localInterfaces = localInterfaces
        self.onSelectLocalInterface = onSelectLocalInterface
        self.probePin = probePin
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(address.isEmpty ? "添加 VPN 网关" : "编辑 VPN 网关",
                  systemImage: "server.rack")
                .font(.title3.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("名称")
                    TextField("例如：办公网", text: $name)
                }
                GridRow {
                    Text("地址")
                    TextField("host:port", text: $address)
                        .font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text("探测网口")
                    Picker("探测网口", selection: Binding(
                        get: { selectedLocalInterface },
                        set: {
                            selectedLocalInterface = $0
                            onSelectLocalInterface($0)
                        }
                    )) {
                        Text("自动选择（系统路由）").tag("")
                        ForEach(localInterfaces) { item in
                            Text(item.displayName).tag(item.name)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("证书指纹")
                    HStack(spacing: 8) {
                        TextField("pin-sha256:...", text: $serverPin)
                            .font(.system(.callout, design: .monospaced))
                        Button {
                            isProbing = true
                            errorMessage = ""
                            Task {
                                do {
                                    serverPin = try await probePin(address, selectedLocalInterface)
                                } catch {
                                    errorMessage = error.localizedDescription
                                }
                                isProbing = false
                            }
                        } label: {
                            if isProbing {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("自动获取", systemImage: "dot.radiowaves.left.and.right")
                            }
                        }
                        .disabled(isProbing || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)

            if !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    if let error = onSave(name, address, serverPin) {
                        errorMessage = error
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          serverPin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          isProbing)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: VPNViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label(model.isConnected ? "SSL VPN 已连接" : "SSL VPN 未连接",
              systemImage: model.isConnected ? "checkmark.shield.fill" : "shield")
        Text(model.gateway)
            .font(.caption)
        if model.isConnected {
            Text("↓ \(model.downloadRateText)   ↑ \(model.uploadRateText)")
                .font(.system(.caption, design: .monospaced))
        }
        Divider()
        Button("打开 SSL VPN Connect") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        if model.isConnected {
            Button("断开连接") { model.disconnect() }
        } else {
            Button("连接") { model.connect() }
                .disabled(model.isBusy)
        }
        Divider()
        Button("退出 SSL VPN Connect") { NSApp.terminate(nil) }
            .disabled(model.isConnected || model.isBusy)
    }
}

#if !RENDER_PREVIEW
@main
struct H3CVPNApp: App {
    @StateObject private var model = VPNViewModel()

    var body: some Scene {
        Window("SSL VPN Connect", id: "main") {
            ContentView(model: model)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appTermination) {
                Button("退出 SSL VPN Connect") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                    .disabled(model.isConnected || model.isBusy)
            }
        }

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: model.isConnected ? "shield.checkered" : "shield")
        }
        .menuBarExtraStyle(.menu)
    }
}
#endif
