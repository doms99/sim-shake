import XCTest
@testable import SimShake

final class RunLogTests: XCTestCase {
    private var root: URL!
    private var directory: LogDirectory!
    private var suiteName: String!
    private var defaults: UserDefaults!
    /// Whole seconds, since the header stores no fractions.
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimShakeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directory = LogDirectory(root: root)
        suiteName = "SimShakeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Format

    func testHeaderRoundTripsMultiLineCommandWithSimulator() throws {
        let script = "echo one\n  echo indented\n\necho {udid}"
        let text = RunLogFormat.header(commandName: "Echo", script: script, simulator: "iPhone 18 Pro - iOS 27.0", startedAt: start)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "Action:    Echo")
        XCTAssertEqual(lines[1], "Command:   echo one")
        XCTAssertEqual(lines[2], "             echo indented")
        XCTAssertEqual(lines[5], "Simulator: iPhone 18 Pro - iOS 27.0")
        XCTAssertTrue(lines[6].hasPrefix("Started:   "))
        XCTAssertEqual(lines[7], String(repeating: "-", count: 40))

        let header = try XCTUnwrap(RunLogFormat.parseHeader(text + "output\n"))
        XCTAssertEqual(header.name, "Echo")
        XCTAssertEqual(header.script, script)
        XCTAssertEqual(header.simulator, "iPhone 18 Pro - iOS 27.0")
        XCTAssertEqual(header.startedAt, start)
    }

    func testHeaderRoundTripsWithoutSimulator() throws {
        let text = RunLogFormat.header(commandName: "Say", script: "say 'hi'", simulator: nil, startedAt: start)
        XCTAssertFalse(text.contains("Simulator:"))
        let header = try XCTUnwrap(RunLogFormat.parseHeader(text))
        XCTAssertEqual(header.name, "Say")
        XCTAssertEqual(header.script, "say 'hi'")
        XCTAssertNil(header.simulator)
        XCTAssertEqual(header.startedAt, start)
    }

    func testHeaderWithoutSeparatorIsRejected() {
        XCTAssertNil(RunLogFormat.parseHeader("Action:    Echo\nCommand:   echo\n"))
        XCTAssertNil(RunLogFormat.parseHeader("just some text\n"))
    }

    func testParsesFooters() {
        let output = "some output\n"
        XCTAssertEqual(RunLogFormat.parseFooter(output + RunLogFormat.footer(.exited(0))), .exited(0))
        XCTAssertEqual(RunLogFormat.parseFooter(output + RunLogFormat.footer(.exited(3))), .exited(3))
        XCTAssertEqual(RunLogFormat.parseFooter(output + RunLogFormat.footer(.stopped)), .stopped)
        XCTAssertEqual(
            RunLogFormat.parseFooter(output + RunLogFormat.footer(.launchFailed("The file (zsh) couldn't be opened."))),
            .launchFailed("The file (zsh) couldn't be opened.")
        )
        XCTAssertNil(RunLogFormat.parseFooter(output))
        XCTAssertNil(RunLogFormat.parseFooter(""))
        XCTAssertNil(RunLogFormat.parseFooter(RunLogFormat.header(commandName: "A", script: "b", simulator: nil, startedAt: start)))
    }

    // MARK: - Directory

    func testFinishedRunReadsBack() throws {
        let id = UUID()
        let writer = try XCTUnwrap(directory.startRun(commandID: id, commandName: "Echo", script: "echo hi", simulator: "iPad - iOS 26.5", startedAt: start))
        writer.append(Data("hi\n".utf8))
        writer.finish(.exited(0))
        writer.finish(.stopped)
        writer.append(Data("late\n".utf8))

        let logs = directory.logs(for: id, activeURLs: [])
        XCTAssertEqual(logs.count, 1)
        let log = try XCTUnwrap(logs.first)
        XCTAssertEqual(log.url, writer.url)
        XCTAssertEqual(log.commandName, "Echo")
        XCTAssertEqual(log.script, "echo hi")
        XCTAssertEqual(log.simulator, "iPad - iOS 26.5")
        XCTAssertEqual(log.startedAt, start)
        XCTAssertEqual(log.status, .exited(0))

        let contents = try String(contentsOf: writer.url, encoding: .utf8)
        XCTAssertTrue(contents.contains("\nhi\n"))
        XCTAssertFalse(contents.contains("late"))
        XCTAssertFalse(contents.contains("Stopped:"))
        XCTAssertEqual(writer.url.deletingLastPathComponent().lastPathComponent, id.uuidString)
    }

    func testRunWithoutFooterIsRunningOnlyWhileActive() throws {
        let id = UUID()
        let writer = try XCTUnwrap(directory.startRun(commandID: id, commandName: "Sleep", script: "sleep 30", simulator: nil, startedAt: start))
        writer.append(Data("waiting\n".utf8))

        XCTAssertEqual(directory.logs(for: id, activeURLs: [writer.url]).first?.status, .running)
        XCTAssertEqual(directory.logs(for: id, activeURLs: []).first?.status, .incomplete)
        writer.finish(.stopped)
        XCTAssertEqual(directory.logs(for: id, activeURLs: [writer.url]).first?.status, .stopped)
    }

    func testLogsAreNewestFirst() throws {
        let id = UUID()
        let urls = try [0, 20, 10].map { offset in
            let writer = try XCTUnwrap(run(id, at: start.addingTimeInterval(TimeInterval(offset))))
            return writer.url
        }
        XCTAssertEqual(directory.logs(for: id, activeURLs: []).map(\.url), [urls[1], urls[2], urls[0]])
    }

    func testRunsStartedInTheSameMillisecondGetDistinctFiles() throws {
        let id = UUID()
        let first = try XCTUnwrap(run(id, at: start))
        let second = try XCTUnwrap(run(id, at: start))
        let third = try XCTUnwrap(run(id, at: start))
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertTrue(second.url.lastPathComponent.hasSuffix("-2.log"))
        XCTAssertEqual(directory.logs(for: id, activeURLs: []).map(\.url), [third.url, second.url, first.url])
    }

    func testIgnoresFilesWithoutHeader() throws {
        let id = UUID()
        _ = try XCTUnwrap(run(id, at: start))
        try Data("not a run\n".utf8).write(to: directory.folder(for: id).appendingPathComponent("other.log"))
        XCTAssertEqual(directory.logs(for: id, activeURLs: []).count, 1)
    }

    func testPruneKeepsNewestAndSparesActiveRuns() throws {
        let id = UUID()
        let urls = try (0..<4).map { offset in
            try XCTUnwrap(run(id, at: start.addingTimeInterval(TimeInterval(offset)))).url
        }
        directory.prune(commandID: id, keep: 2, excluding: [urls[0]])
        XCTAssertEqual(directory.logs(for: id, activeURLs: []).map(\.url), [urls[3], urls[2], urls[0]])
    }

    func testRemoveLogsDeletesFolder() throws {
        let id = UUID()
        _ = try XCTUnwrap(run(id, at: start))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.folder(for: id).path))
        directory.removeLogs(for: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.folder(for: id).path))
        XCTAssertEqual(directory.logs(for: id, activeURLs: []), [])
    }

    // MARK: - Stores

    @MainActor
    func testKeepCountDefaultsClampsAndPersists() {
        let store = RunLogStore(directory: directory, defaults: defaults)
        XCTAssertEqual(store.keepCount, 50)
        store.keepCount = 0
        XCTAssertEqual(store.keepCount, 1)
        store.keepCount = 5000
        XCTAssertEqual(store.keepCount, 1000)
        store.keepCount = 7
        XCTAssertEqual(RunLogStore(directory: directory, defaults: defaults).keepCount, 7)
    }

    @MainActor
    func testRemovingCommandsDeletesTheirLogs() throws {
        let logs = RunLogStore(directory: directory, defaults: defaults)
        let store = CommandStore(defaults: defaults, logs: logs)
        let a = Command(name: "A", command: "echo a", symbol: "terminal")
        let b = Command(name: "B", command: "echo b", symbol: "terminal")
        store.commands = [a, b]
        _ = try XCTUnwrap(run(a.id, at: start))
        _ = try XCTUnwrap(run(b.id, at: start))

        store.commands.removeAll { $0.id == a.id }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.folder(for: a.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.folder(for: b.id).path))

        store.commands[0].name = "Renamed"
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.folder(for: b.id).path))

        store.restoreDefaults()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.folder(for: b.id).path))
    }

    /// A finished run of `commandID` started at `date`.
    private func run(_ commandID: UUID, at date: Date) -> RunLogWriter? {
        let writer = directory.startRun(commandID: commandID, commandName: "Echo", script: "echo", simulator: nil, startedAt: date)
        writer?.finish(.exited(0))
        return writer
    }
}
