import Foundation

/// An installed Xcode with `simctl`, as read from its bundle.
struct XcodeInstall: Hashable, Sendable {
    /// Symlinks resolved, so Xcodes' `Xcode.app` link and its target are the same install.
    var appURL: URL
    var version: String
    var build: String
    /// `RC` or `Beta`, judged by the app's file name; `nil` for a stable release.
    var prereleaseLabel: String?

    var developerDirectory: URL { appURL.appendingPathComponent("Contents/Developer", isDirectory: true) }

    /// `Xcode 27.1 RC`, `Xcode 28.0 Beta`, `Xcode 27.1`.
    var displayName: String {
        ["Xcode", version, prereleaseLabel ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static let defaultFolders = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
    ]

    /// `nil` unless the app is an Xcode with an executable `simctl`.
    static func load(appURL: URL) -> XcodeInstall? {
        // Rebuilt from the path so installs found by scanning and by path compare equal.
        let appURL = URL(fileURLWithPath: appURL.resolvingSymlinksInPath().path, isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        guard let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")),
              info["CFBundleIdentifier"] as? String == "com.apple.dt.Xcode",
              FileManager.default.isExecutableFile(atPath: contents.appendingPathComponent("Developer/usr/bin/simctl").path)
        else { return nil }
        let versionInfo = NSDictionary(contentsOf: contents.appendingPathComponent("version.plist"))
        return XcodeInstall(
            appURL: appURL,
            version: info["CFBundleShortVersionString"] as? String ?? "",
            build: versionInfo?["ProductBuildVersion"] as? String ?? info["DTXcodeBuild"] as? String ?? "",
            prereleaseLabel: prereleaseLabel(forAppName: appURL.lastPathComponent)
        )
    }

    /// The bundle doesn't say whether it's a pre-release, so this goes by Xcodes' naming
    /// (`Xcode-28.0.0-Beta.3.app`, `Xcode-27.1.0-Release.Candidate.app`).
    static func prereleaseLabel(forAppName name: String) -> String? {
        let words = name.lowercased()
            .replacingOccurrences(of: #"[-_.]"#, with: " ", options: .regularExpression)
        if words.contains("beta") { return "Beta" }
        if words.contains("release candidate") || words.split(separator: " ").contains("rc") { return "RC" }
        return nil
    }

    /// The Xcodes at the top level of `folders`, best first.
    static func discover(in folders: [URL] = defaultFolders) -> [XcodeInstall] {
        var seenPaths = Set<String>()
        var installs: [XcodeInstall] = []
        for folder in folders {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )) ?? []
            for entry in entries where entry.pathExtension == "app" {
                guard let install = load(appURL: entry), seenPaths.insert(install.appURL.path).inserted else { continue }
                installs.append(install)
            }
        }
        return installs.sorted(by: preferredOrder)
    }

    /// Stable before pre-release, then the highest version, then the highest build.
    static func preferredOrder(_ lhs: XcodeInstall, _ rhs: XcodeInstall) -> Bool {
        if (lhs.prereleaseLabel == nil) != (rhs.prereleaseLabel == nil) {
            return lhs.prereleaseLabel == nil
        }
        for (l, r) in [(lhs.version, rhs.version), (lhs.build, rhs.build)] {
            let order = l.compare(r, options: .numeric)
            if order != .orderedSame { return order == .orderedDescending }
        }
        return lhs.appURL.path < rhs.appURL.path
    }
}

/// Which Xcode SimShake uses, and why.
struct XcodeResolution: Equatable, Sendable {
    enum Source: Sendable {
        case pinned
        case xcodeSelect
        case discovered
        case none
    }

    var developerDirectory: URL?
    /// `nil` for an `xcode-select` directory that isn't inside an `.app`.
    var install: XcodeInstall?
    var source: Source
    /// A pinned Xcode is set but no longer valid, so this is the Automatic choice.
    var pinnedMissing = false
}

/// Resolves the Xcode to pass as `DEVELOPER_DIR`, fresh on every call so installs added or
/// deleted since are picked up without restarting.
enum XcodeSelector {
    static let pinnedPathKey = "xcodePath"

    /// The pinned Xcode if it's still valid; otherwise `xcode-select -p` if it has `simctl`;
    /// otherwise the best discovered install.
    static func resolve(
        pinnedPath: String?,
        load: (URL) -> XcodeInstall?,
        xcodeSelectPath: () -> String?,
        hasSimctl: (URL) -> Bool,
        discover: () -> [XcodeInstall]
    ) -> XcodeResolution {
        var pinnedMissing = false
        if let pinnedPath {
            if let install = load(URL(fileURLWithPath: pinnedPath)) {
                return XcodeResolution(developerDirectory: install.developerDirectory, install: install, source: .pinned)
            }
            pinnedMissing = true
        }
        if let path = xcodeSelectPath() {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            if hasSimctl(directory) {
                // `…/Xcode.app/Contents/Developer` → `…/Xcode.app`.
                let app = directory.deletingLastPathComponent().deletingLastPathComponent()
                let install = directory.path.hasSuffix(".app/Contents/Developer") ? load(app) : nil
                return XcodeResolution(
                    developerDirectory: install?.developerDirectory ?? directory,
                    install: install,
                    source: .xcodeSelect,
                    pinnedMissing: pinnedMissing
                )
            }
        }
        if let install = discover().first {
            return XcodeResolution(developerDirectory: install.developerDirectory, install: install, source: .discovered, pinnedMissing: pinnedMissing)
        }
        return XcodeResolution(developerDirectory: nil, install: nil, source: .none, pinnedMissing: pinnedMissing)
    }

    static func current(defaults: UserDefaults = .standard) -> XcodeResolution {
        resolveOnThisMac(pinnedPath: defaults.string(forKey: pinnedPathKey))
    }

    /// What Automatic resolves to, ignoring any pin.
    static func automatic() -> XcodeResolution {
        resolveOnThisMac(pinnedPath: nil)
    }

    /// This process's environment, plus `DEVELOPER_DIR` when there's a developer directory.
    static func environment(for developerDirectory: URL?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let developerDirectory {
            environment["DEVELOPER_DIR"] = developerDirectory.path
        }
        return environment
    }

    private static func resolveOnThisMac(pinnedPath: String?) -> XcodeResolution {
        resolve(
            pinnedPath: pinnedPath,
            load: XcodeInstall.load(appURL:),
            xcodeSelectPath: xcodeSelectPath,
            hasSimctl: { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("usr/bin/simctl").path) },
            discover: { XcodeInstall.discover() }
        )
    }

    /// `xcode-select -p`, or `nil` if it fails (e.g. nothing selected).
    private static func xcodeSelectPath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        // Drain the pipe before waiting so the child can't block on a full pipe.
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}

/// What Settings shows about the Xcode choice; the pin is persisted to UserDefaults.
@MainActor
final class XcodeSettings: ObservableObject {
    static let shared = XcodeSettings(defaults: .standard)

    /// The pinned Xcode's app path; `nil` is Automatic.
    @Published var pinnedPath: String? = nil {
        didSet {
            if let pinnedPath {
                defaults.set(pinnedPath, forKey: XcodeSelector.pinnedPathKey)
            } else {
                defaults.removeObject(forKey: XcodeSelector.pinnedPathKey)
            }
            resolution = XcodeSelector.current(defaults: defaults)
        }
    }

    @Published private(set) var installs: [XcodeInstall] = []
    @Published private(set) var automatic = XcodeResolution(developerDirectory: nil, install: nil, source: .none)
    @Published private(set) var resolution = XcodeResolution(developerDirectory: nil, install: nil, source: .none)

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        pinnedPath = defaults.string(forKey: XcodeSelector.pinnedPathKey)
        reload()
    }

    /// Rescans installs and re-resolves, picking up a pin changed with `defaults write`.
    func reload() {
        let stored = defaults.string(forKey: XcodeSelector.pinnedPathKey)
        if stored != pinnedPath {
            pinnedPath = stored
        }
        installs = XcodeInstall.discover()
        automatic = XcodeSelector.automatic()
        resolution = XcodeSelector.current(defaults: defaults)
    }
}
