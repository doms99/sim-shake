import XCTest
@testable import SimShake

final class SimShakeTests: XCTestCase {
    private let fixture = Data("""
    {
      "devices" : {
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0" : [
          {
            "dataPath" : "/Users/me/Library/Developer/CoreSimulator/Devices/A422F529-8DED-436C-AFCB-ACE41CE09672/data",
            "dataPathSize" : 9761452032,
            "logPath" : "/Users/me/Library/Logs/CoreSimulator/A422F529-8DED-436C-AFCB-ACE41CE09672",
            "udid" : "A422F529-8DED-436C-AFCB-ACE41CE09672",
            "isAvailable" : true,
            "lastUsedAt" : "2026-09-29T10:01:24Z",
            "logPathSize" : 704512,
            "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
            "state" : "Booted",
            "name" : "iPhone 18 Pro"
          },
          {
            "dataPath" : "/Users/me/Library/Developer/CoreSimulator/Devices/E8C53351-26DA-4099-9FB3-C219A8200116/data",
            "dataPathSize" : 18337792,
            "logPath" : "/Users/me/Library/Logs/CoreSimulator/E8C53351-26DA-4099-9FB3-C219A8200116",
            "udid" : "E8C53351-26DA-4099-9FB3-C219A8200116",
            "isAvailable" : true,
            "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max",
            "state" : "Shutdown",
            "name" : "iPhone 18 Pro Max"
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.watchOS-12-0" : [
          {
            "dataPath" : "/Users/me/Library/Developer/CoreSimulator/Devices/5B0C1E2A-6D8F-4C47-9E1B-2F3A4B5C6D7E/data",
            "dataPathSize" : 18337792,
            "logPath" : "/Users/me/Library/Logs/CoreSimulator/5B0C1E2A-6D8F-4C47-9E1B-2F3A4B5C6D7E",
            "udid" : "5B0C1E2A-6D8F-4C47-9E1B-2F3A4B5C6D7E",
            "isAvailable" : true,
            "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm",
            "state" : "Booted",
            "name" : "Apple Watch Series 11 (46mm)"
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-26-5" : [
          {
            "dataPath" : "/Users/me/Library/Developer/CoreSimulator/Devices/CA874CA5-7E4C-4321-BB6F-8A7F303283B9/data",
            "dataPathSize" : 4301971456,
            "logPath" : "/Users/me/Library/Logs/CoreSimulator/CA874CA5-7E4C-4321-BB6F-8A7F303283B9",
            "udid" : "CA874CA5-7E4C-4321-BB6F-8A7F303283B9",
            "isAvailable" : true,
            "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-16GB",
            "state" : "Booted",
            "name" : "iPad Pro 13-inch (M4)"
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.xrOS-3-0" : [
          {
            "dataPath" : "/Users/me/Library/Developer/CoreSimulator/Devices/1C6524BB-24DB-4FBC-BA1A-FB2907A0E49D/data",
            "dataPathSize" : 18337792,
            "logPath" : "/Users/me/Library/Logs/CoreSimulator/1C6524BB-24DB-4FBC-BA1A-FB2907A0E49D",
            "udid" : "1C6524BB-24DB-4FBC-BA1A-FB2907A0E49D",
            "isAvailable" : true,
            "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro",
            "state" : "Shutdown",
            "name" : "Apple Vision Pro"
          }
        ]
      }
    }
    """.utf8)

    func testRuntimeLabels() {
        XCTAssertEqual(Simulator.runtimeLabel(for: "com.apple.CoreSimulator.SimRuntime.iOS-27-0"), "iOS 27.0")
        XCTAssertEqual(Simulator.runtimeLabel(for: "com.apple.CoreSimulator.SimRuntime.iOS-26-5"), "iOS 26.5")
        XCTAssertEqual(Simulator.runtimeLabel(for: "com.apple.CoreSimulator.SimRuntime.watchOS-12-0"), "watchOS 12.0")
        XCTAssertEqual(Simulator.runtimeLabel(for: "com.apple.CoreSimulator.SimRuntime.tvOS-27-0"), "tvOS 27.0")
        XCTAssertEqual(Simulator.runtimeLabel(for: "com.apple.CoreSimulator.SimRuntime.xrOS-3-0"), "visionOS 3.0")
    }

    func testParsesOnlyBootedSimulatorsSortedByPlatformThenName() throws {
        let simulators = try Simulator.parseBooted(from: fixture)

        XCTAssertEqual(simulators.map(\.udid), [
            "CA874CA5-7E4C-4321-BB6F-8A7F303283B9",
            "A422F529-8DED-436C-AFCB-ACE41CE09672",
            "5B0C1E2A-6D8F-4C47-9E1B-2F3A4B5C6D7E",
        ])
        XCTAssertEqual(simulators.map(\.menuTitle), [
            "iPad Pro 13-inch (M4) - iOS 26.5",
            "iPhone 18 Pro - iOS 27.0",
            "Apple Watch Series 11 (46mm) - watchOS 12.0",
        ])

        let iPhone = simulators[1]
        XCTAssertEqual(iPhone.name, "iPhone 18 Pro")
        XCTAssertEqual(iPhone.runtimeID, "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        XCTAssertEqual(iPhone.deviceTypeID, "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro")
    }

    func testParsesEmptyDeviceList() throws {
        XCTAssertEqual(try Simulator.parseBooted(from: Data(#"{"devices":{}}"#.utf8)), [])
    }

    func testDeviceIcons() {
        let type = "com.apple.CoreSimulator.SimDeviceType."
        XCTAssertEqual(Simulator.symbolName(deviceTypeID: type + "iPhone-18-Pro", platform: "iOS"), "iphone")
        XCTAssertEqual(Simulator.symbolName(deviceTypeID: type + "iPad-Pro-13-inch-M4-16GB", platform: "iOS"), "ipad")
        XCTAssertEqual(Simulator.symbolName(deviceTypeID: type + "Apple-Watch-Series-11-46mm", platform: "watchOS"), "applewatch")
        XCTAssertEqual(Simulator.symbolName(deviceTypeID: type + "Apple-TV-4K-3rd-generation-4K", platform: "tvOS"), "appletv")
        XCTAssertEqual(Simulator.symbolName(deviceTypeID: type + "Apple-Vision-Pro", platform: "visionOS"), "visionpro")
        XCTAssertEqual(Simulator.symbolName(deviceTypeID: "", platform: "tvOS"), "appletv")
        XCTAssertEqual(Simulator.symbolName(deviceTypeID: "", platform: "Unknown"), "iphone")
    }

    func testSimulatorPlaceholder() {
        let command = Command(name: "Open", command: "xcrun simctl openurl {udid} https://example.com && echo {udid}", symbol: "link")
        XCTAssertTrue(command.usesSimulator)
        XCTAssertEqual(command.resolved(udid: "ABC"), "xcrun simctl openurl ABC https://example.com && echo ABC")

        let plain = Command(name: "Say", command: "say hi", symbol: "terminal")
        XCTAssertFalse(plain.usesSimulator)
        XCTAssertEqual(plain.resolved(udid: "ABC"), "say hi")
    }

    func testParametersInOrderOfFirstAppearance() {
        let command = Command(name: "P", command: "run {{ url }} {{bundle id}} {{url}} {{ }} {udid}", symbol: "link")
        XCTAssertEqual(command.parameters.map(\.name), ["url", "bundle id"])
        XCTAssertTrue(Command(name: "S", command: "say hi", symbol: "terminal").parameters.isEmpty)
    }

    func testUdidInsideParameterIsNotTheSimulatorPlaceholder() {
        XCTAssertFalse(Command(name: "P", command: "echo {{udid}}", symbol: "link").usesSimulator)
        XCTAssertTrue(Command(name: "P", command: "echo {{udid}} {udid}", symbol: "link").usesSimulator)
    }

    func testShellQuoting() {
        XCTAssertEqual(Command.shellQuoted("hello world"), "'hello world'")
        XCTAssertEqual(Command.shellQuoted("it's"), #"'it'\''s'"#)
        XCTAssertEqual(Command.shellQuoted(""), "''")
    }

    func testResolvesParametersAsQuotedArguments() {
        let command = Command(name: "Open", command: "xcrun simctl openurl {udid} {{url}} && echo {{url}}", symbol: "link")
        XCTAssertEqual(
            command.resolved(udid: "ABC", values: ["url": "https://example.com/?a=1&b=2;c"]),
            "xcrun simctl openurl ABC 'https://example.com/?a=1&b=2;c' && echo 'https://example.com/?a=1&b=2;c'"
        )
    }

    func testInsertedValuesAreNotSubstitutedAgain() {
        let command = Command(name: "Echo", command: "echo {{a}} {{b}} {udid}", symbol: "terminal")
        XCTAssertEqual(
            command.resolved(udid: "ABC", values: ["a": "{udid}", "b": "{{a}}"]),
            "echo '{udid}' '{{a}}' ABC"
        )
    }

    func testBlankPlaceholderStaysLiteral() {
        let command = Command(name: "Echo", command: "echo {{ }} {{x}}", symbol: "terminal")
        XCTAssertEqual(command.resolved(udid: nil, values: ["x": "y"]), "echo {{ }} 'y'")
    }

    func testDefaultCommandsContainShake() throws {
        let shake = try XCTUnwrap(CommandStore.defaultCommands.first { $0.name == "Shake" })
        XCTAssertEqual(shake.command, "xcrun simctl spawn {udid} notifyutil -p com.apple.UIKit.SimulatorShake")
        XCTAssertEqual(shake.symbol, "iphone.gen3.radiowaves.left.and.right")
        XCTAssertTrue(shake.usesSimulator)
    }

    // MARK: - File parameters

    func testFileParameterExtensionsAreNormalized() {
        let command = Command(name: "F", command: "a {x:file} {y:file:} {z:file: .PNG, jpg,,png ,.Jpeg }", symbol: "doc")
        XCTAssertEqual(command.parameters, [
            .init(name: "x", kind: .file(extensions: [])),
            .init(name: "y", kind: .file(extensions: [])),
            .init(name: "z", kind: .file(extensions: ["png", "jpg", "jpeg"])),
        ])
    }

    func testTextAndFileParametersKeepCommandOrder() {
        let command = Command(name: "F", command: "run {{ a }} { b :file:png} {{c}} {d:file} {udid}", symbol: "doc")
        XCTAssertEqual(command.parameters, [
            .init(name: "a", kind: .text),
            .init(name: "b", kind: .file(extensions: ["png"])),
            .init(name: "c", kind: .text),
            .init(name: "d", kind: .file(extensions: [])),
        ])
    }

    func testRepeatedFileParameterMergesExtensions() {
        let filtered = Command(name: "F", command: "cp {p:file:png,jpg} {p:file:jpg,gif} {p:file:png}", symbol: "doc")
        XCTAssertEqual(filtered.parameters, [.init(name: "p", kind: .file(extensions: ["png", "jpg", "gif"]))])

        let unfiltered = Command(name: "F", command: "cp {p:file:png} {p:file} {p:file:jpg}", symbol: "doc")
        XCTAssertEqual(unfiltered.parameters, [.init(name: "p", kind: .file(extensions: []))])
    }

    func testTextAndFileWithSameNameIsOneFileParameter() {
        let command = Command(name: "F", command: "echo {{photo}} {photo:file:png} {{photo}}", symbol: "doc")
        XCTAssertEqual(command.parameters, [.init(name: "photo", kind: .file(extensions: ["png"]))])
        XCTAssertEqual(command.resolved(udid: nil, values: ["photo": "/a b.png"]), "echo '/a b.png' '/a b.png' '/a b.png'")
    }

    func testMalformedFilePlaceholdersStayLiteral() {
        let command = Command(name: "F", command: "echo { :file} {a:dir} {a:filex} {a:File}", symbol: "doc")
        XCTAssertTrue(command.parameters.isEmpty)
        XCTAssertEqual(command.resolved(udid: nil), "echo { :file} {a:dir} {a:filex} {a:File}")
    }

    func testDoubleBracedFileIsATextParameter() {
        let command = Command(name: "F", command: "echo {{a:file}}", symbol: "doc")
        XCTAssertEqual(command.parameters, [.init(name: "a:file", kind: .text)])
    }

    func testUdidFileIsAFileParameterNotTheSimulator() {
        let command = Command(name: "F", command: "echo {udid:file}", symbol: "doc")
        XCTAssertEqual(command.parameters, [.init(name: "udid", kind: .file(extensions: []))])
        XCTAssertFalse(command.usesSimulator)
    }

    func testResolvesFileParameterAsQuotedArgument() {
        let command = Command(name: "Add", command: "xcrun simctl addmedia {udid} {media:file:png}", symbol: "photo")
        XCTAssertEqual(
            command.resolved(udid: "ABC", values: ["media": "/Users/me/My Photos/it's.png"]),
            #"xcrun simctl addmedia ABC '/Users/me/My Photos/it'\''s.png'"#
        )
    }

    func testNormalizedValue() {
        let file = Command.Parameter(name: "f", kind: .file(extensions: []))
        let text = Command.Parameter(name: "t", kind: .text)
        let home = NSHomeDirectory()
        XCTAssertEqual(file.normalizedValue("  ~/Desktop/a.png \n"), home + "/Desktop/a.png")
        XCTAssertEqual(file.normalizedValue(" /tmp/a b.png "), "/tmp/a b.png")
        XCTAssertEqual(text.normalizedValue("  ~/Desktop \n"), "~/Desktop")
    }

    func testDefaultCommandsContainAddMedia() throws {
        let addMedia = try XCTUnwrap(CommandStore.defaultCommands.first { $0.name == "Add Media" })
        XCTAssertEqual(addMedia.command, "xcrun simctl addmedia {udid} {media:file:png,jpg,jpeg,heic,gif,mp4,mov,m4v}")
        XCTAssertEqual(addMedia.symbol, "photo.on.rectangle")
        XCTAssertTrue(addMedia.usesSimulator)
        XCTAssertEqual(addMedia.parameters.map(\.name), ["media"])
        guard case .file = addMedia.parameters.first?.kind else {
            return XCTFail("media should be a file parameter")
        }
    }
}

/// Adding Add Media to command lists saved before it existed.
final class AddMediaMigrationTests: XCTestCase {
    private var root: URL!
    private var directory: LogDirectory!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimShakeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "SimShakeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        directory = LogDirectory(root: root)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testSavedCommandsGetAddMediaOnce() throws {
        let saved = [Command(name: "Echo", command: "echo hi", symbol: "terminal")]
        defaults.set(try JSONEncoder().encode(saved), forKey: "commands")

        let store = makeStore()
        XCTAssertEqual(store.commands.map(\.name), ["Echo", "Add Media"])
        XCTAssertEqual(store.commands[0], saved[0])

        let reopened = makeStore()
        XCTAssertEqual(reopened.commands.map(\.name), ["Echo", "Add Media"])
        XCTAssertEqual(reopened.commands.map(\.id), store.commands.map(\.id))
    }

    @MainActor
    func testDeletedAddMediaIsNotAddedBack() throws {
        let saved = [Command(name: "Echo", command: "echo hi", symbol: "terminal")]
        defaults.set(try JSONEncoder().encode(saved), forKey: "commands")

        let store = makeStore()
        store.commands.removeAll { $0.name == "Add Media" }

        XCTAssertEqual(makeStore().commands.map(\.name), ["Echo"])
    }

    @MainActor
    func testFreshInstallHasAddMediaOnce() {
        let store = makeStore()
        XCTAssertEqual(store.commands.map(\.name), ["Shake", "Add Media"])

        store.commands[0].name = "Shake It" // Saves the list.
        XCTAssertEqual(makeStore().commands.map(\.name), ["Shake It", "Add Media"])
    }

    @MainActor
    private func makeStore() -> CommandStore {
        CommandStore(defaults: defaults, logs: RunLogStore(directory: directory, defaults: defaults))
    }
}
