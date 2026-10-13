import XCTest
@testable import SimShake

final class XcodeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimShakeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func install(_ name: String, version: String, build: String = "27A1", prerelease: String? = nil) -> XcodeInstall {
        XcodeInstall(appURL: URL(fileURLWithPath: "/Applications/\(name).app"), version: version, build: build, prereleaseLabel: prerelease)
    }

    // MARK: - Pre-release labels

    func testPrereleaseLabels() {
        XCTAssertEqual(XcodeInstall.prereleaseLabel(forAppName: "Xcode-27.1.0-Release.Candidate.app"), "RC")
        XCTAssertEqual(XcodeInstall.prereleaseLabel(forAppName: "Xcode-28.0.0-Beta.3.app"), "Beta")
        XCTAssertEqual(XcodeInstall.prereleaseLabel(forAppName: "Xcode_16_beta.app"), "Beta")
        XCTAssertEqual(XcodeInstall.prereleaseLabel(forAppName: "Xcode-27.1-RC.app"), "RC")
        XCTAssertNil(XcodeInstall.prereleaseLabel(forAppName: "Xcode-27.1.0.app"))
        XCTAssertNil(XcodeInstall.prereleaseLabel(forAppName: "Xcode.app"))
        XCTAssertNil(XcodeInstall.prereleaseLabel(forAppName: "Xcode-Source.app"))
    }

    func testDisplayNames() {
        XCTAssertEqual(install("Xcode-27.1.0-Release.Candidate", version: "27.1", prerelease: "RC").displayName, "Xcode 27.1 RC")
        XCTAssertEqual(install("Xcode-28.0.0-Beta", version: "28.0", prerelease: "Beta").displayName, "Xcode 28.0 Beta")
        XCTAssertEqual(install("Xcode-27.1.0", version: "27.1").displayName, "Xcode 27.1")
    }

    // MARK: - Ordering

    func testStableBeatsNewerPrerelease() {
        let stable = install("Xcode-27.0.0", version: "27.0")
        let beta = install("Xcode-28.0.0-Beta", version: "28.0", prerelease: "Beta")
        XCTAssertEqual([beta, stable].sorted(by: XcodeInstall.preferredOrder), [stable, beta])
    }

    func testVersionsCompareNumerically() {
        let minor = install("Xcode-27.1.0", version: "27.1")
        let patch = install("Xcode-27.0.1", version: "27.0.1")
        XCTAssertEqual([patch, minor].sorted(by: XcodeInstall.preferredOrder), [minor, patch])

        let ten = install("Xcode-27.10.0", version: "27.10")
        let nine = install("Xcode-27.9.0", version: "27.9")
        XCTAssertEqual([nine, ten].sorted(by: XcodeInstall.preferredOrder), [ten, nine])
    }

    func testBuildBreaksVersionTie() {
        let older = install("Xcode-A", version: "27.1", build: "27A9274")
        let newer = install("Xcode-B", version: "27.1", build: "27A9275")
        XCTAssertEqual([older, newer].sorted(by: XcodeInstall.preferredOrder), [newer, older])
    }

    // MARK: - Resolution

    private let pinned = XcodeInstall(appURL: URL(fileURLWithPath: "/Applications/Xcode-26.0.0.app"), version: "26.0", build: "26A1", prereleaseLabel: nil)
    private let selected = XcodeInstall(appURL: URL(fileURLWithPath: "/Applications/Xcode-27.0.0.app"), version: "27.0", build: "27A1", prereleaseLabel: nil)
    private let discovered = XcodeInstall(appURL: URL(fileURLWithPath: "/Applications/Xcode-27.1.0.app"), version: "27.1", build: "27A2", prereleaseLabel: nil)

    private func resolve(pinnedPath: String?, xcodeSelect: String?, discover: [XcodeInstall]) -> XcodeResolution {
        let known = [pinned, selected, discovered]
        return XcodeSelector.resolve(
            pinnedPath: pinnedPath,
            load: { url in known.first { $0.appURL.path == url.path } },
            xcodeSelectPath: { xcodeSelect },
            hasSimctl: { url in known.contains { $0.developerDirectory.path == url.path } },
            discover: { discover }
        )
    }

    func testValidPinWins() {
        let resolution = resolve(pinnedPath: pinned.appURL.path, xcodeSelect: selected.developerDirectory.path, discover: [discovered])
        XCTAssertEqual(resolution.source, .pinned)
        XCTAssertEqual(resolution.install, pinned)
        XCTAssertEqual(resolution.developerDirectory, pinned.developerDirectory)
        XCTAssertFalse(resolution.pinnedMissing)
    }

    func testMissingPinFallsBackToAutomatic() {
        let resolution = resolve(pinnedPath: "/Applications/Nope.app", xcodeSelect: selected.developerDirectory.path, discover: [discovered])
        XCTAssertEqual(resolution.source, .xcodeSelect)
        XCTAssertEqual(resolution.install, selected)
        XCTAssertTrue(resolution.pinnedMissing)
    }

    func testValidXcodeSelectWinsInAutomatic() {
        let resolution = resolve(pinnedPath: nil, xcodeSelect: selected.developerDirectory.path, discover: [discovered])
        XCTAssertEqual(resolution.source, .xcodeSelect)
        XCTAssertEqual(resolution.install, selected)
        XCTAssertEqual(resolution.developerDirectory, selected.developerDirectory)
        XCTAssertFalse(resolution.pinnedMissing)
    }

    func testCommandLineToolsXcodeSelectFallsBackToDiscovered() {
        let resolution = resolve(pinnedPath: nil, xcodeSelect: "/Library/Developer/CommandLineTools", discover: [discovered, selected])
        XCTAssertEqual(resolution.source, .discovered)
        XCTAssertEqual(resolution.install, discovered)
        XCTAssertEqual(resolution.developerDirectory, discovered.developerDirectory)
    }

    func testNothingFound() {
        let resolution = resolve(pinnedPath: nil, xcodeSelect: nil, discover: [])
        XCTAssertEqual(resolution.source, .none)
        XCTAssertNil(resolution.developerDirectory)
        XCTAssertNil(resolution.install)
    }

    // MARK: - Discovery

    func testDiscoverFindsXcodesWithSimctlOnce() throws {
        let xcode = try makeApp("Xcode-27.1.0-Release.Candidate", bundleID: "com.apple.dt.Xcode", simctl: true, versionPlist: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Xcode.app"), withDestinationURL: xcode)
        _ = try makeApp("Other", bundleID: "com.example.Other", simctl: true)
        _ = try makeApp("Xcode-26.0.0", bundleID: "com.apple.dt.Xcode", simctl: false)

        let installs = XcodeInstall.discover(in: [root])

        XCTAssertEqual(installs.count, 1)
        let install = try XCTUnwrap(installs.first)
        XCTAssertEqual(install.appURL.path, xcode.resolvingSymlinksInPath().path)
        XCTAssertEqual(install.version, "27.1")
        XCTAssertEqual(install.build, "27A9275")
        XCTAssertEqual(install.prereleaseLabel, "RC")
        XCTAssertEqual(install.displayName, "Xcode 27.1 RC")
    }

    func testBuildFallsBackToInfoPlist() throws {
        let xcode = try makeApp("Xcode-27.1.0", bundleID: "com.apple.dt.Xcode", simctl: true)
        XCTAssertEqual(XcodeInstall.load(appURL: xcode)?.build, "27A9274")
    }

    private func makeApp(_ name: String, bundleID: String, simctl: Bool, versionPlist: Bool = false) throws -> URL {
        let app = root.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let bin = contents.appendingPathComponent("Developer/usr/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let info: NSDictionary = [
            "CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": "27.1",
            "DTXcodeBuild": "27A9274",
        ]
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        if versionPlist {
            let version: NSDictionary = ["ProductBuildVersion": "27A9275"]
            try version.write(to: contents.appendingPathComponent("version.plist"))
        }
        if simctl {
            let tool = bin.appendingPathComponent("simctl")
            try Data("#!/bin/sh\n".utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        return app
    }
}
