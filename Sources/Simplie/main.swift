import AppKit
import Foundation
import SwiftUI

@main
struct SimplieApp: App {
    @State private var monitor = SystemMonitor()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            DashboardView(monitor: monitor)
        } label: {
            Label {
                Text(monitor.snapshot.battery.menuTitle)
            } icon: {
                Image(systemName: "cpu")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var snapshot = SystemSnapshot.load()
    @Published private(set) var workingVPN: String?
    @Published private(set) var vpnMessage: String?
    private var isRefreshing = false

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let updated = await Task.detached(priority: .utility) {
                SystemSnapshot.load()
            }.value
            snapshot = updated
            isRefreshing = false
        }
    }

    func toggleVPN(_ vpn: VPNProfile) {
        guard workingVPN == nil else { return }
        workingVPN = vpn.name
        vpnMessage = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.runVPNCommand(vpn.isConnected ? "stop" : "start", name: vpn.name)
            }.value
            vpnMessage = result
            workingVPN = nil
            refresh()
        }
    }

    func selectExpressVPNLocation(_ location: String) {
        runExpressVPNCommand(["connect", location])
    }

    func quickConnectExpressVPN() {
        runExpressVPNCommand(["connect", snapshot.expressVPN?.currentRegion ?? "smart"])
    }

    func disconnectExpressVPN() {
        runExpressVPNCommand(["disconnect"])
    }

    func toggleMullvad(_ mullvad: MullvadInfo) {
        runMullvadCommand([mullvad.isConnected ? "disconnect" : "connect"], expectedState: mullvad.isConnected ? "Disconnected" : "Connected")
    }

    func selectMullvadLocation(_ location: MullvadLocation) {
        var arguments = ["relay", "set", "location", location.countryCode]
        if let cityCode = location.cityCode { arguments.append(cityCode) }
        runMullvadCommand(arguments, expectedState: "Connected", reconnectAfterSelection: true)
    }

    func toggleCloudflareWARP(_ warp: CloudflareWARPInfo) {
        runWARPCommand(warp.isConnected ? "disconnect" : "connect", expectedConnected: !warp.isConnected)
    }

    nonisolated private static func runVPNCommand(_ action: String, name: String) -> String? {
        let result = Command.run("/usr/sbin/scutil", ["--nc", action, name])
        guard result.status == 0 else {
            return result.output.isEmpty ? "Could not change the VPN connection." : result.output
        }
        return nil
    }

    private func runExpressVPNCommand(_ arguments: [String]) {
        guard workingVPN == nil else { return }
        workingVPN = "ExpressVPN"
        vpnMessage = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                await Self.runExpressVPNCommand(arguments)
            }.value
            vpnMessage = result
            workingVPN = nil
            refresh()
        }
    }

    nonisolated private static func runExpressVPNCommand(_ arguments: [String]) async -> String? {
        let cliPath = SystemSnapshot.expressVPNCLIPath()
        guard let cliPath else { return "ExpressVPN command-line tool was not found." }
        let result = Command.run(cliPath, ["--timeout", "30"] + arguments)
        guard result.status == 0 else {
            return result.output.isEmpty ? "ExpressVPN could not change the connection." : result.output
        }

        let action = arguments.first
        let requestedRegion = arguments.dropFirst().first
        var lastState = "Unknown"
        var lastRegion = "Unknown"
        for _ in 0..<30 {
            lastState = Command.run(cliPath, ["get", "connectionstate"]).output
            lastRegion = Command.run(cliPath, ["get", "region"]).output
            if action == "disconnect", lastState == "Disconnected" { return nil }
            if action == "connect", lastState == "Connected",
               requestedRegion == "smart" || requestedRegion == lastRegion {
                return nil
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return "ExpressVPN did not finish the request (\(lastState), \(lastRegion))."
    }

    private func runMullvadCommand(_ arguments: [String], expectedState: String, reconnectAfterSelection: Bool = false) {
        guard workingVPN == nil else { return }
        workingVPN = "Mullvad"
        vpnMessage = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                await Self.runMullvadCommand(arguments, expectedState: expectedState, reconnectAfterSelection: reconnectAfterSelection)
            }.value
            vpnMessage = result
            workingVPN = nil
            refresh()
        }
    }

    nonisolated private static func runMullvadCommand(_ arguments: [String], expectedState: String, reconnectAfterSelection: Bool) async -> String? {
        guard let cliPath = SystemSnapshot.mullvadCLIPath() else { return "Mullvad command-line tool was not found." }
        let firstResult = Command.run(cliPath, arguments)
        guard firstResult.status == 0 else {
            return firstResult.output.isEmpty ? "Mullvad could not change the connection." : firstResult.output
        }
        if reconnectAfterSelection {
            let connectResult = Command.run(cliPath, ["connect"])
            guard connectResult.status == 0 else {
                return connectResult.output.isEmpty ? "Mullvad could not connect." : connectResult.output
            }
        }

        var lastStatus = "Unknown"
        for _ in 0..<30 {
            lastStatus = Command.run(cliPath, ["status"]).output
            let connected = lastStatus.localizedCaseInsensitiveContains("connected") &&
                !lastStatus.localizedCaseInsensitiveContains("disconnected")
            if expectedState == "Disconnected", !connected { return nil }
            if expectedState == "Connected", connected { return nil }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return "Mullvad did not finish the request: \(lastStatus)"
    }

    private func runWARPCommand(_ action: String, expectedConnected: Bool) {
        guard workingVPN == nil else { return }
        workingVPN = "Cloudflare WARP"
        vpnMessage = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                await Self.runWARPCommand(action, expectedConnected: expectedConnected)
            }.value
            vpnMessage = result
            workingVPN = nil
            refresh()
        }
    }

    nonisolated private static func runWARPCommand(_ action: String, expectedConnected: Bool) async -> String? {
        guard let cliPath = SystemSnapshot.warpCLIPath() else { return "Cloudflare WARP command-line tool was not found." }
        let result = Command.run(cliPath, [action])
        guard result.status == 0 else {
            return result.output.isEmpty ? "Cloudflare WARP could not change the connection." : result.output
        }
        var lastStatus = "Unknown"
        for _ in 0..<20 {
            lastStatus = Command.run(cliPath, ["status"]).output
            let connected = lastStatus.localizedCaseInsensitiveContains("Connected") &&
                !lastStatus.localizedCaseInsensitiveContains("Disconnected")
            if connected == expectedConnected { return nil }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return "Cloudflare WARP did not finish the request: \(lastStatus)"
    }
}

struct VPNProfile: Identifiable, Sendable {
    let name: String
    let state: String
    var id: String { name }
    var isConnected: Bool { state == "Connected" }
}

struct ExpressVPNInfo: Sendable {
    let isConnected: Bool
    let currentRegion: String
    let locations: [String]
}

struct MullvadLocation: Identifiable, Sendable {
    let country: String
    let countryCode: String
    let city: String?
    let cityCode: String?
    var id: String { "\(countryCode)-\(cityCode ?? "")" }
    var title: String { city.map { "\($0), \(country)" } ?? country }
}

struct MullvadInfo: Sendable {
    let isConnected: Bool
    let currentLocation: String
    let locations: [MullvadLocation]
}

struct CloudflareWARPInfo: Sendable {
    let isConnected: Bool
}

struct DetectedVPNApp: Identifiable, Sendable {
    let id: String
    let name: String
    let path: String
    let isRunning: Bool
}

struct VPNLocationChoice: Identifiable {
    enum Provider {
        case expressVPN
        case mullvad
    }

    let id: String
    let provider: Provider
    let providerName: String
    let location: String
    let title: String
}

struct RunningProcess: Identifiable, Sendable {
    let name: String
    let cpu: Double
    var id: String { name }
}

struct BatteryStatus: Sendable {
    let percentage: Int?
    let state: String
    let remaining: String?

    var menuTitle: String { percentage.map { "\($0)%" } ?? "System" }
    var symbol: String {
        guard let percentage else { return "bolt.horizontal.circle" }
        if state == "charging" { return "battery.100percent.bolt" }
        switch percentage {
        case 0..<20: return "battery.25percent"
        case 20..<50: return "battery.50percent"
        case 50..<80: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

struct SystemSnapshot: Sendable {
    let battery: BatteryStatus
    let memoryUsed: UInt64
    let memoryTotal: UInt64
    let diskUsed: UInt64
    let diskTotal: UInt64
    let uptime: String
    let updatedAt: Date
    let processes: [RunningProcess]
    let expressVPN: ExpressVPNInfo?
    let mullvad: MullvadInfo?
    let cloudflareWARP: CloudflareWARPInfo?
    let otherVPNApps: [DetectedVPNApp]
    let vpnProfiles: [VPNProfile]

    private static let expressVPNLocations = loadExpressVPNLocations()
    private static let mullvadLocations = loadMullvadLocations()

    static func load() -> SystemSnapshot {
        let battery = readBattery()
        let (memoryUsed, memoryTotal) = readMemory()
        let (diskUsed, diskTotal) = readDisk()
        return SystemSnapshot(
            battery: battery,
            memoryUsed: memoryUsed,
            memoryTotal: memoryTotal,
            diskUsed: diskUsed,
            diskTotal: diskTotal,
            uptime: formatUptime(ProcessInfo.processInfo.systemUptime),
            updatedAt: Date(),
            processes: readProcesses(),
            expressVPN: readExpressVPN(),
            mullvad: readMullvad(),
            cloudflareWARP: readCloudflareWARP(),
            otherVPNApps: readOtherVPNApps(),
            vpnProfiles: readVPNProfiles()
        )
    }

    static func expressVPNCLIPath() -> String? {
        executable(named: "expressvpnctl", candidates: [
            "/usr/local/bin/expressvpnctl",
            "/opt/homebrew/bin/expressvpnctl",
            "/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl"
        ])
    }

    static func mullvadCLIPath() -> String? {
        executable(named: "mullvad", candidates: [
            "/usr/bin/mullvad",
            "/usr/local/bin/mullvad",
            "/opt/homebrew/bin/mullvad",
            "/Applications/Mullvad VPN.app/Contents/Resources/mullvad",
            "/Applications/Mullvad VPN.app/Contents/MacOS/mullvad"
        ])
    }

    static func warpCLIPath() -> String? {
        executable(named: "warp-cli", candidates: [
            "/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli",
            "/usr/local/bin/warp-cli",
            "/opt/homebrew/bin/warp-cli"
        ])
    }

    private static func executable(named name: String, candidates: [String]) -> String? {
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }
        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return pathValue.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent(name).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func loadExpressVPNLocations() -> [String] {
        guard let path = expressVPNCLIPath() else { return [] }
        let result = Command.run(path, ["get", "regions"])
        guard result.status == 0 else { return [] }
        return result.output.split(whereSeparator: \.isNewline).map(String.init)
    }

    private static func readExpressVPN() -> ExpressVPNInfo? {
        guard let path = expressVPNCLIPath() else { return nil }
        let connection = Command.run(path, ["get", "connectionstate"])
        let region = Command.run(path, ["get", "region"])
        guard connection.status == 0, region.status == 0, !region.output.isEmpty else { return nil }
        return ExpressVPNInfo(
            isConnected: connection.output == "Connected",
            currentRegion: region.output,
            locations: expressVPNLocations
        )
    }

    private static func loadMullvadLocations() -> [MullvadLocation] {
        guard let path = mullvadCLIPath() else { return [] }
        let result = Command.run(path, ["relay", "list"])
        guard result.status == 0 else { return [] }
        let countryPattern = try? NSRegularExpression(pattern: #"^([^()]+?)\s+\(([a-z]{2})\)$"#)
        let cityPattern = try? NSRegularExpression(pattern: #"^(.+?)\s+\(([a-z0-9]{3})\)$"#)
        var currentCountry: (name: String, code: String)?
        var locations: [MullvadLocation] = []
        for rawLine in result.output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let indentation = line.prefix(while: \.isWhitespace).count
            let content = line.trimmingCharacters(in: .whitespaces)
            let range = NSRange(content.startIndex..., in: content)
            if indentation == 0,
               let match = countryPattern?.firstMatch(in: content, range: range),
               let nameRange = Range(match.range(at: 1), in: content),
               let codeRange = Range(match.range(at: 2), in: content) {
                currentCountry = (String(content[nameRange]), String(content[codeRange]))
            } else if indentation > 0,
                      let country = currentCountry,
                      let match = cityPattern?.firstMatch(in: content, range: range),
                      let nameRange = Range(match.range(at: 1), in: content),
                      let codeRange = Range(match.range(at: 2), in: content) {
                locations.append(MullvadLocation(
                    country: country.name,
                    countryCode: country.code,
                    city: String(content[nameRange]),
                    cityCode: String(content[codeRange])
                ))
            }
        }
        return locations
    }

    private static func readMullvad() -> MullvadInfo? {
        guard let path = mullvadCLIPath() else { return nil }
        let result = Command.run(path, ["status"])
        guard result.status == 0 else { return nil }
        let status = result.output
        let isConnected = status.localizedCaseInsensitiveContains("connected") &&
            !status.localizedCaseInsensitiveContains("disconnected")
        let relayPattern = try? NSRegularExpression(pattern: #"(?i)([a-z]{2}-[a-z0-9-]+)(?:\s+\(([^)]+)\))?"#)
        let statusRange = NSRange(status.startIndex..., in: status)
        let relayMatch = relayPattern?.firstMatch(in: status, range: statusRange)
        let relayName = relayMatch.flatMap { Range($0.range(at: 1), in: status).map { String(status[$0]) } }
        let cityName = relayMatch.flatMap { Range($0.range(at: 2), in: status).map { String(status[$0]) } }
        return MullvadInfo(
            isConnected: isConnected,
            currentLocation: isConnected ? (cityName ?? relayName ?? "Connected") : "Disconnected",
            locations: mullvadLocations
        )
    }

    private static func readCloudflareWARP() -> CloudflareWARPInfo? {
        guard let path = warpCLIPath() else { return nil }
        let result = Command.run(path, ["status"])
        guard result.status == 0 else { return nil }
        return CloudflareWARPInfo(
            isConnected: result.output.localizedCaseInsensitiveContains("Connected") &&
                !result.output.localizedCaseInsensitiveContains("Disconnected")
        )
    }

    private static func readOtherVPNApps() -> [DetectedVPNApp] {
        let appDirectories = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications")]
        let knownProviders: [(name: String, aliases: [String])] = [
            ("ExpressVPN", ["expressvpn", "express vpn"]),
            ("Mullvad", ["mullvad"]),
            ("Cloudflare WARP", ["cloudflare warp", "com.cloudflare.1dot1dot1dot1"]),
            ("NordVPN", ["nordvpn", "nord vpn"]),
            ("Proton VPN", ["protonvpn", "proton vpn"]),
            ("Surfshark", ["surfshark"]),
            ("Windscribe", ["windscribe"]),
            ("CyberGhost", ["cyberghost"]),
            ("Private Internet Access", ["private internet access", "pia vpn"]),
            ("IPVanish", ["ipvanish"]),
            ("TunnelBear", ["tunnelbear"]),
            ("hide.me VPN", ["hide.me vpn", "hide.me"]),
            ("VPN app", ["vpn"])
        ]
        let runningOutput = Command.run("/bin/ps", ["-A", "-o", "args="]).output.lowercased()
        let expressVPNWorks = expressVPNCLIPath().map { Command.run($0, ["get", "connectionstate"]).status == 0 } ?? false
        let mullvadWorks = mullvadCLIPath().map { Command.run($0, ["status"]).status == 0 } ?? false
        let warpWorks = warpCLIPath().map { Command.run($0, ["status"]).status == 0 } ?? false
        let directlySupported = Set([
            expressVPNWorks ? "ExpressVPN" : nil,
            mullvadWorks ? "Mullvad" : nil,
            warpWorks ? "Cloudflare WARP" : nil
        ].compactMap { $0 })
        var detected: [DetectedVPNApp] = []
        for directory in appDirectories {
            guard let apps = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            for app in apps where app.pathExtension == "app" {
                let bundle = Bundle(url: app)
                let displayName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? app.deletingPathExtension().lastPathComponent
                let searchText = "\(displayName) \(app.lastPathComponent) \(bundle?.bundleIdentifier ?? "")".lowercased()
                guard let provider = knownProviders.first(where: { item in item.aliases.contains(where: searchText.contains) }) else { continue }
                if directlySupported.contains(provider.name) { continue }
                let id = bundle?.bundleIdentifier ?? provider.name.lowercased().replacingOccurrences(of: " ", with: "-")
                detected.append(DetectedVPNApp(
                    id: id,
                    name: provider.name == "VPN app" ? displayName : provider.name,
                    path: app.path,
                    isRunning: runningOutput.contains(app.path.lowercased()) ||
                        (provider.name != "VPN app" && provider.aliases.contains(where: runningOutput.contains))
                ))
            }
        }
        return detected.sorted { $0.name < $1.name }
    }

    private static func readBattery() -> BatteryStatus {
        let output = Command.run("/usr/bin/pmset", ["-g", "batt"]).output
        guard let line = output.split(separator: "\n").first(where: { $0.contains("%") }) else {
            return BatteryStatus(percentage: nil, state: "unavailable", remaining: nil)
        }
        let percentage = line.range(of: #"\d+(?=%)"#, options: .regularExpression)
            .flatMap { Int(line[$0]) }
        let lowerLine = line.lowercased()
        let state = lowerLine.contains("charging") && !lowerLine.contains("discharging")
            ? "charging"
            : lowerLine.contains("discharging") ? "on battery" : "charged"
        let remaining = line.range(of: #"(?<=time remaining: )\d+:\d+"#, options: .regularExpression)
            .map { String(line[$0]) }
        return BatteryStatus(percentage: percentage, state: state, remaining: remaining)
    }

    private static func readMemory() -> (UInt64, UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        let output = Command.run("/usr/bin/vm_stat", []).output
        let pageSize = output.range(of: #"page size of \d+ bytes"#, options: .regularExpression)
            .flatMap { UInt64(output[$0].filter(\.isNumber)) } ?? 4096
        let reclaimablePages = ["Pages free", "Pages inactive", "Pages speculative", "Pages purgeable"]
            .reduce(UInt64(0)) { total, prefix in
                total + pageCount(named: prefix, in: output)
            }
        let available = min(total, reclaimablePages * pageSize)
        return (total - available, total)
    }

    private static func pageCount(named prefix: String, in output: String) -> UInt64 {
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }),
              let digits = line.split(whereSeparator: { !$0.isNumber }).last else { return 0 }
        return UInt64(digits) ?? 0
    }

    private static func readDisk() -> (UInt64, UInt64) {
        guard let values = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let total = values[.systemSize] as? NSNumber,
              let free = values[.systemFreeSize] as? NSNumber else { return (0, 0) }
        return (total.uint64Value - min(total.uint64Value, free.uint64Value), total.uint64Value)
    }

    private static func readProcesses() -> [RunningProcess] {
        let output = Command.run("/bin/ps", ["-A", "-o", "%cpu=,comm="]).output
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, let cpu = Double(fields[0]) else { return nil }
            let name = URL(fileURLWithPath: String(fields[1])).lastPathComponent
            return RunningProcess(name: name, cpu: cpu)
        }
        .sorted { $0.cpu > $1.cpu }
        .prefix(5)
        .map { $0 }
    }

    private static func readVPNProfiles() -> [VPNProfile] {
        let output = Command.run("/usr/sbin/scutil", ["--nc", "list"]).output
        let pattern = #"\(([^)]+)\).*?"([^"]+)"\s+\[VPN:"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let value = String(line)
            let range = NSRange(value.startIndex..., in: value)
            guard let match = regex.firstMatch(in: value, range: range),
                  let stateRange = Range(match.range(at: 1), in: value),
                  let nameRange = Range(match.range(at: 2), in: value) else { return nil }
            return VPNProfile(name: String(value[nameRange]), state: String(value[stateRange]))
        }
    }

    private static func formatUptime(_ seconds: TimeInterval) -> String {
        let totalHours = Int(seconds / 3600)
        let days = totalHours / 24
        let hours = totalHours % 24
        if days > 0 { return "\(days)d \(hours)h" }
        return "\(hours)h \(Int(seconds / 60) % 60)m"
    }
}

private struct Command {
    let status: Int32
    let output: String

    static func run(_ path: String, _ arguments: [String]) -> Command {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Command(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return Command(status: -1, output: error.localizedDescription)
        }
    }
}

struct DashboardView: View {
    @ObservedObject var monitor: SystemMonitor
    @State private var locationQuery = ""
    @FocusState private var locationSearchFocused: Bool

    private var memoryFraction: Double {
        guard monitor.snapshot.memoryTotal > 0 else { return 0 }
        return Double(monitor.snapshot.memoryUsed) / Double(monitor.snapshot.memoryTotal)
    }

    private var diskFraction: Double {
        guard monitor.snapshot.diskTotal > 0 else { return 0 }
        return Double(monitor.snapshot.diskUsed) / Double(monitor.snapshot.diskTotal)
    }

    private var matchingVPNLocations: [VPNLocationChoice] {
        var locations: [VPNLocationChoice] = []
        if let expressVPN = monitor.snapshot.expressVPN {
            locations += expressVPN.locations.map {
                VPNLocationChoice(id: "express:\($0)", provider: .expressVPN, providerName: "ExpressVPN", location: $0, title: locationTitle($0))
            }
        }
        if let mullvad = monitor.snapshot.mullvad {
            locations += mullvad.locations.map {
                VPNLocationChoice(id: "mullvad:\($0.id)", provider: .mullvad, providerName: "Mullvad", location: $0.id, title: $0.title)
            }
        }
        let query = locationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return locations }
        return locations.filter {
            $0.location.localizedCaseInsensitiveContains(query) ||
                $0.title.localizedCaseInsensitiveContains(query) ||
                $0.providerName.localizedCaseInsensitiveContains(query)
        }
    }

    private func connectFirstMatchingLocation() {
        guard let location = matchingVPNLocations.first else { return }
        connect(location)
        locationSearchFocused = false
    }

    private func connect(_ location: VPNLocationChoice) {
        switch location.provider {
        case .expressVPN:
            monitor.selectExpressVPNLocation(location.location)
        case .mullvad:
            guard let mullvadLocation = monitor.snapshot.mullvad?.locations.first(where: { $0.id == location.location }) else { return }
            monitor.selectMullvadLocation(mullvadLocation)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            batterySection
            Divider()
            usageSection
            Divider()
            processesSection
            Divider()
            vpnSection
            if let message = monitor.vpnMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !matchingVPNLocations.isEmpty || monitor.snapshot.expressVPN != nil || monitor.snapshot.mullvad != nil {
                Divider()
                quickLocationSearch
            }
            HStack {
                Text("Updated \(monitor.snapshot.updatedAt, style: .time)").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button(action: monitor.refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh system information")
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.plain)
                .help("Quit Simplie")
            }
        }
        .padding(18)
        .frame(width: 350)
        .onAppear {
            monitor.refresh()
            locationSearchFocused = monitor.snapshot.expressVPN != nil
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Simplie Overview").font(.title3.weight(.semibold))
                Text("Uptime · \(monitor.snapshot.uptime)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "Mac")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var batterySection: some View {
        HStack(spacing: 12) {
            Image(systemName: monitor.snapshot.battery.symbol)
                .font(.system(size: 25, weight: .regular))
                .foregroundStyle(monitor.snapshot.battery.percentage ?? 100 < 20 ? .orange : .green)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(monitor.snapshot.battery.percentage.map { "Battery · \($0)%" } ?? "Battery unavailable")
                    .font(.headline)
                Text([monitor.snapshot.battery.state, monitor.snapshot.battery.remaining.map { "\($0) remaining" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var usageSection: some View {
        VStack(spacing: 13) {
            UsageRow(title: "Memory", detail: "\(formatBytes(monitor.snapshot.memoryUsed)) of \(formatBytes(monitor.snapshot.memoryTotal))", fraction: memoryFraction, tint: .blue)
            UsageRow(title: "Storage", detail: "\(formatBytes(monitor.snapshot.diskUsed)) of \(formatBytes(monitor.snapshot.diskTotal))", fraction: diskFraction, tint: .orange)
        }
    }

    private var processesSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("ACTIVE PROCESSES").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if monitor.snapshot.processes.isEmpty {
                Text("Process activity unavailable").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(monitor.snapshot.processes) { process in
                    HStack {
                        Text(process.name).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1f%% CPU", process.cpu))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var vpnSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("VPN LOCATIONS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network")!)
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
            if let expressVPN = monitor.snapshot.expressVPN {
                expressVPNSection(expressVPN)
            }
            if let mullvad = monitor.snapshot.mullvad {
                mullvadSection(mullvad)
            }
            if let warp = monitor.snapshot.cloudflareWARP {
                warpSection(warp)
            }
            if !monitor.snapshot.otherVPNApps.isEmpty {
                otherVPNAppsSection
            }
            if !monitor.snapshot.vpnProfiles.isEmpty {
                ForEach(monitor.snapshot.vpnProfiles) { vpn in
                    HStack(spacing: 8) {
                        Image(systemName: vpn.isConnected ? "checkmark.circle.fill" : "globe")
                            .foregroundStyle(vpn.isConnected ? .green : .secondary)
                            .frame(width: 16)
                        Text(vpn.name).lineLimit(1)
                        Spacer(minLength: 3)
                        Button {
                            monitor.toggleVPN(vpn)
                        } label: {
                            if monitor.workingVPN == vpn.name {
                                ProgressView().controlSize(.small).frame(width: 54)
                            } else {
                                Text(vpn.isConnected ? "Disconnect" : "Connect").frame(width: 62)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(monitor.workingVPN != nil)
                    }
                    .font(.caption)
                }
            }
            if monitor.snapshot.expressVPN == nil,
               monitor.snapshot.mullvad == nil,
               monitor.snapshot.cloudflareWARP == nil,
               monitor.snapshot.otherVPNApps.isEmpty,
               monitor.snapshot.vpnProfiles.isEmpty {
                Text("No VPN app or macOS VPN profile detected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func mullvadSection(_ mullvad: MullvadInfo) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Circle().fill(mullvad.isConnected ? .green : .secondary).frame(width: 7, height: 7)
                Text(mullvad.isConnected ? "Mullvad · Connected" : "Mullvad · Disconnected")
                    .font(.caption.weight(.medium))
                Spacer()
                Text(mullvad.currentLocation).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button {
                    monitor.toggleMullvad(mullvad)
                } label: {
                    if monitor.workingVPN == "Mullvad" {
                        ProgressView().controlSize(.small).frame(width: 58)
                    } else {
                        Text(mullvad.isConnected ? "Disconnect" : "Connect").frame(width: 58)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(monitor.workingVPN != nil)
            }
            if mullvad.locations.isEmpty {
                Text("Location list unavailable. Use the Mullvad app to choose a relay.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func warpSection(_ warp: CloudflareWARPInfo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Circle().fill(warp.isConnected ? .green : .secondary).frame(width: 7, height: 7)
                Text(warp.isConnected ? "Cloudflare WARP · Connected" : "Cloudflare WARP · Disconnected")
                    .font(.caption.weight(.medium))
                Spacer()
                Button {
                    monitor.toggleCloudflareWARP(warp)
                } label: {
                    if monitor.workingVPN == "Cloudflare WARP" {
                        ProgressView().controlSize(.small).frame(width: 58)
                    } else {
                        Text(warp.isConnected ? "Disconnect" : "Connect").frame(width: 58)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(monitor.workingVPN != nil)
            }
            Text("WARP selects its route automatically; it has no city picker.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var otherVPNAppsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(monitor.snapshot.otherVPNApps) { app in
                HStack {
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundStyle(app.isRunning ? .green : .secondary)
                        .frame(width: 16)
                    Text(app.name).font(.caption.weight(.medium))
                    Text(app.isRunning ? "Running" : "Installed")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: app.path))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            Text("This provider manages its own connection and locations.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func expressVPNSection(_ vpn: ExpressVPNInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(vpn.isConnected ? .green : .secondary)
                    .frame(width: 7, height: 7)
                Text(vpn.isConnected ? "ExpressVPN · Connected" : "ExpressVPN · Disconnected")
                    .font(.caption.weight(.medium))
            }
            Text("Current location: \(locationTitle(vpn.currentRegion))")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button {
                    if vpn.isConnected {
                        monitor.disconnectExpressVPN()
                    } else {
                        monitor.quickConnectExpressVPN()
                    }
                } label: {
                    Label(vpn.isConnected ? "Turn VPN Off" : "Turn VPN On", systemImage: vpn.isConnected ? "power" : "bolt.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(monitor.workingVPN != nil)

                Button {
                    monitor.quickConnectExpressVPN()
                } label: {
                    Label(vpn.isConnected ? "Reconnect" : "Quick Connect", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(monitor.workingVPN != nil)
                .help(vpn.isConnected ? "Reconnect to the selected location" : "Connect to the selected location")
            }
        }
    }

    private var quickLocationSearch: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search VPN locations", text: $locationQuery)
                    .textFieldStyle(.plain)
                    .focused($locationSearchFocused)
                    .autocorrectionDisabled()
                    .onSubmit(connectFirstMatchingLocation)
                if !locationQuery.isEmpty {
                    Button {
                        locationQuery = ""
                        locationSearchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear location search")
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))

            if !locationQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if matchingVPNLocations.isEmpty {
                    Text("No matching locations").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 9)
                } else {
                    VStack(spacing: 1) {
                        ForEach(matchingVPNLocations.prefix(5)) { location in
                            HStack(spacing: 6) {
                                Text(location.title).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(location.providerName).font(.caption2).foregroundStyle(.secondary)
                                Button {
                                    connect(location)
                                    locationSearchFocused = false
                                } label: {
                                    if monitor.workingVPN != nil {
                                        ProgressView().controlSize(.small).frame(width: 54)
                                    } else {
                                        Text("Connect").frame(width: 54)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .disabled(monitor.workingVPN != nil)
                            }
                            .font(.caption)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(3)
                    .background(.background, in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }

    private func locationTitle(_ location: String) -> String {
        switch location {
        case "smart": return "Smart Location"
        default:
            let parts = location.split(separator: "-", omittingEmptySubsequences: false)
            guard let country = parts.first else { return location }
            let countryName: String
            switch country {
            case "usa": countryName = "USA"
            case "uk": countryName = "UK"
            case "uae": countryName = "UAE"
            default: countryName = country.capitalized
            }
            let city = parts.dropFirst().joined(separator: " ").capitalized
            return city.isEmpty ? countryName : "\(city), \(countryName)"
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .binary)
    }
}

private struct UsageRow: View {
    let title: String
    let detail: String
    let fraction: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.caption.weight(.medium))
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: fraction).tint(tint)
        }
    }
}