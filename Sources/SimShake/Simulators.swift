import Foundation

struct Simulator: Hashable {
    var udid: String
    var name: String
    var runtimeID: String
    var deviceTypeID: String

    var platform: String { Self.runtimeComponents(runtimeID).platform }
    var runtimeLabel: String { Self.runtimeLabel(for: runtimeID) }
    var menuTitle: String { "\(name) - \(runtimeLabel)" }
    var symbolName: String { Self.symbolName(deviceTypeID: deviceTypeID, platform: platform) }
}

struct SimctlError: LocalizedError {
    var status: Int32
    var errorDescription: String? { "simctl exited with status \(status)" }
}

extension Simulator {
    /// Runs `xcrun simctl list devices -j` synchronously with `developerDirectory` as `DEVELOPER_DIR`
    /// and returns the booted devices.
    static func listBooted(developerDirectory: URL?) throws -> [Simulator] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "-j"]
        process.environment = XcodeSelector.environment(for: developerDirectory)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        try process.run()
        // Drain the pipe before waiting so large output can't block the child.
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SimctlError(status: process.terminationStatus)
        }
        return try parseBooted(from: data)
    }

    /// Parses `simctl list devices -j` output, keeping booted devices sorted by platform, then name.
    static func parseBooted(from data: Data) throws -> [Simulator] {
        let list = try JSONDecoder().decode(DeviceList.self, from: data)
        let booted = list.devices.flatMap { runtimeID, devices in
            devices
                .filter { $0.state == "Booted" }
                .map {
                    Simulator(
                        udid: $0.udid,
                        name: $0.name,
                        runtimeID: runtimeID,
                        deviceTypeID: $0.deviceTypeIdentifier ?? ""
                    )
                }
        }
        return booted.sorted { lhs, rhs in
            for (l, r) in [(lhs.platform, rhs.platform), (lhs.name, rhs.name), (lhs.runtimeLabel, rhs.runtimeLabel)] {
                let order = l.localizedStandardCompare(r)
                if order != .orderedSame { return order == .orderedAscending }
            }
            return lhs.udid < rhs.udid
        }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-27-0` → `iOS 27.0`; `xrOS-*` → `visionOS`.
    static func runtimeLabel(for runtimeID: String) -> String {
        let (platform, version) = runtimeComponents(runtimeID)
        return version.isEmpty ? platform : "\(platform) \(version)"
    }

    static func runtimeComponents(_ runtimeID: String) -> (platform: String, version: String) {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        let tail = runtimeID.hasPrefix(prefix) ? String(runtimeID.dropFirst(prefix.count)) : runtimeID
        let parts = tail.split(separator: "-").map(String.init)
        guard let first = parts.first else { return (tail, "") }
        let platform = first == "xrOS" ? "visionOS" : first
        return (platform, parts.dropFirst().joined(separator: "."))
    }

    static func symbolName(deviceTypeID: String, platform: String) -> String {
        let type = deviceTypeID.lowercased()
        if type.contains("ipad") { return "ipad" }
        if type.contains("iphone") || type.contains("ipod") { return "iphone" }
        if type.contains("watch") { return "applewatch" }
        if type.contains("apple-tv") { return "appletv" }
        if type.contains("vision") { return "visionpro" }
        switch platform {
        case "watchOS": return "applewatch"
        case "tvOS": return "appletv"
        case "visionOS": return "visionpro"
        default: return "iphone"
        }
    }
}

private struct DeviceList: Decodable {
    struct Device: Decodable {
        var udid: String
        var name: String
        var state: String
        var deviceTypeIdentifier: String?
    }

    var devices: [String: [Device]]
}
