import Foundation
import os

/// One run of a command, as read back from its log file.
struct RunLog: Identifiable, Hashable {
    enum Status: Hashable {
        case running
        case exited(Int32)
        case stopped
        case launchFailed(String)
        /// No footer and no live process, e.g. SimShake crashed mid-run.
        case incomplete
    }

    var url: URL
    var commandName: String
    /// The command as it ran, with `{udid}` and parameters filled in.
    var script: String
    var simulator: String?
    var startedAt: Date
    var status: Status

    var id: URL { url }
}

/// The plain-text layout of a log file: a header, the command's output, then a footer.
enum RunLogFormat {
    enum End: Sendable {
        case exited(Int32)
        case stopped
        case launchFailed(String)
    }

    static let separator = String(repeating: "-", count: 40)

    /// Values start in this column, so multi-line commands stay aligned.
    private static let fieldWidth = 11

    static func header(commandName: String, script: String, simulator: String?, startedAt: Date) -> String {
        var lines = [field("Action", commandName), field("Command", script)]
        if let simulator {
            lines.append(field("Simulator", simulator))
        }
        lines.append(field("Started", format(startedAt)))
        lines.append(separator)
        return lines.joined(separator: "\n") + "\n"
    }

    static func footer(_ end: End, at date: Date = Date()) -> String {
        let line = switch end {
        case .exited(let status): "\(label("Finished"))\(format(date)) (exit status \(status))"
        case .stopped: "\(label("Stopped"))\(format(date)) (SimShake quit)"
        case .launchFailed(let error): "Failed to start: \(format(date)) (\(error.replacingOccurrences(of: "\n", with: " ")))"
        }
        return "\n\(separator)\n\(line)\n"
    }

    /// Reads the fields above the first separator; a line starting with whitespace continues the previous field.
    static func parseHeader(_ text: String) -> (name: String, script: String, simulator: String?, startedAt: Date)? {
        var fields: [(key: String, value: String)] = []
        var foundSeparator = false
        for line in text.components(separatedBy: "\n") {
            if line == separator {
                foundSeparator = true
                break
            }
            if let first = line.first, first.isWhitespace, !fields.isEmpty {
                let indent = min(fieldWidth, line.prefix { $0 == " " }.count)
                fields[fields.count - 1].value += "\n" + line.dropFirst(indent)
            } else if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon])
                let rest = line[line.index(after: colon)...]
                let padding = min(max(0, fieldWidth - key.count - 1), rest.prefix { $0 == " " }.count)
                fields.append((key, String(rest.dropFirst(padding))))
            }
        }
        guard foundSeparator else { return nil }
        func value(_ key: String) -> String? { fields.first { $0.key == key }?.value }
        guard let name = value("Action"),
              let script = value("Command"),
              let started = value("Started"),
              let startedAt = dateFormatter.date(from: started)
        else { return nil }
        return (name, script, value("Simulator"), startedAt)
    }

    /// The status recorded in the footer, judged by the last non-empty line; `nil` if there is none.
    static func parseFooter(_ tail: String) -> RunLog.Status? {
        guard let line = tail.components(separatedBy: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return nil
        }
        if let rest = afterDate(in: line, label: label("Finished")),
           let match = rest.wholeMatch(of: #/ \(exit status (-?\d+)\)/#),
           let status = Int32(match.output.1) {
            return .exited(status)
        }
        if afterDate(in: line, label: label("Stopped")) == " (SimShake quit)" {
            return .stopped
        }
        if let rest = afterDate(in: line, label: "Failed to start: "), rest.hasPrefix(" ("), rest.hasSuffix(")") {
            return .launchFailed(String(rest.dropFirst(2).dropLast()))
        }
        return nil
    }

    /// What follows `label` and a formatted date at the start of `line`.
    private static func afterDate(in line: String, label: String) -> Substring? {
        guard line.hasPrefix(label) else { return nil }
        let rest = line.dropFirst(label.count)
        guard let match = rest.prefixMatch(of: #/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}/#) else { return nil }
        return rest[match.range.upperBound...]
    }

    private static func format(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static func label(_ name: String) -> String {
        (name + ":").padding(toLength: fieldWidth, withPad: " ", startingAt: 0)
    }

    private static func field(_ name: String, _ value: String) -> String {
        let indent = String(repeating: " ", count: fieldWidth)
        return label(name) + value.components(separatedBy: "\n").joined(separator: "\n" + indent)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZ"
        return formatter
    }()
}

/// Appends a run's output to its log file from any thread. Write errors are logged, never thrown,
/// so logging can't interrupt the command.
final class RunLogWriter: Sendable {
    private struct State {
        var handle: FileHandle?
        var hasLoggedError = false
    }

    let url: URL
    private let state: OSAllocatedUnfairLock<State>

    init(url: URL, handle: FileHandle) {
        self.url = url
        state = OSAllocatedUnfairLock(uncheckedState: State(handle: handle))
    }

    func append(_ data: Data) {
        state.withLockUnchecked { state in
            guard let handle = state.handle else { return }
            write(data, to: handle, state: &state)
        }
    }

    /// Writes the footer and closes the file; later calls (and appends) do nothing.
    func finish(_ end: RunLogFormat.End) {
        state.withLockUnchecked { state in
            guard let handle = state.handle else { return }
            state.handle = nil
            write(Data(RunLogFormat.footer(end).utf8), to: handle, state: &state)
            do {
                try handle.close()
            } catch {
                NSLog("SimShake: failed to close log %@: %@", url.path, error.localizedDescription)
            }
        }
    }

    private func write(_ data: Data, to handle: FileHandle, state: inout State) {
        do {
            try handle.write(contentsOf: data)
        } catch {
            // A full disk fails every chunk; one message is enough.
            guard !state.hasLoggedError else { return }
            state.hasLoggedError = true
            NSLog("SimShake: failed to write log %@: %@", url.path, error.localizedDescription)
        }
    }
}

/// The log files on disk, one folder per command. The files themselves are the only record of runs.
struct LogDirectory: Sendable {
    var root: URL

    private static let headerLength = 8192
    private static let footerLength = 1024

    func folder(for commandID: UUID) -> URL {
        root.appendingPathComponent(commandID.uuidString, isDirectory: true)
    }

    /// Creates the run's file with its header; `nil` if that fails, in which case the command runs unlogged.
    func startRun(commandID: UUID, commandName: String, script: String, simulator: String?, startedAt: Date) -> RunLogWriter? {
        let folder = folder(for: commandID)
        let header = Data(RunLogFormat.header(commandName: commandName, script: script, simulator: simulator, startedAt: startedAt).utf8)
        let base = Self.fileNameFormatter.string(from: startedAt)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for attempt in 1...1000 {
                let url = folder.appendingPathComponent(attempt == 1 ? "\(base).log" : "\(base)-\(attempt).log", isDirectory: false)
                do {
                    try header.write(to: url, options: .withoutOverwriting)
                } catch CocoaError.fileWriteFileExists {
                    continue
                }
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                return RunLogWriter(url: url, handle: handle)
            }
            throw CocoaError(.fileWriteFileExists)
        } catch {
            NSLog("SimShake: couldn't create a log for %@ in %@: %@", commandName, folder.path, error.localizedDescription)
        }
        return nil
    }

    /// The command's runs, newest first. Files without a readable header are skipped.
    func logs(for commandID: UUID, activeURLs: Set<URL>) -> [RunLog] {
        let folder = folder(for: commandID)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names
            .filter { $0.hasSuffix(".log") }
            .compactMap { read(folder.appendingPathComponent($0, isDirectory: false), activeURLs: activeURLs) }
            .sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
                // Same second: the file names carry milliseconds and a `-2`, `-3`… suffix.
                let lhsName = lhs.url.deletingPathExtension().lastPathComponent
                let rhsName = rhs.url.deletingPathExtension().lastPathComponent
                return lhsName.compare(rhsName, options: .numeric) == .orderedDescending
            }
    }

    /// Deletes all but the newest `keep` runs, sparing running ones.
    func prune(commandID: UUID, keep: Int, excluding activeURLs: Set<URL>) {
        for log in logs(for: commandID, activeURLs: activeURLs).dropFirst(max(0, keep)) where !activeURLs.contains(log.url) {
            do {
                try FileManager.default.removeItem(at: log.url)
            } catch {
                NSLog("SimShake: failed to delete log %@: %@", log.url.path, error.localizedDescription)
            }
        }
    }

    func removeLogs(for commandID: UUID) {
        let folder = folder(for: commandID)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            NSLog("SimShake: failed to delete logs %@: %@", folder.path, error.localizedDescription)
        }
    }

    private func read(_ url: URL, activeURLs: Set<URL>) -> RunLog? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: Self.headerLength),
              let header = RunLogFormat.parseHeader(String(decoding: head, as: UTF8.self))
        else { return nil }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(Self.footerLength) ? size - UInt64(Self.footerLength) : 0)
        let tail = (try? handle.readToEnd()) ?? Data()
        let status = RunLogFormat.parseFooter(String(decoding: tail, as: UTF8.self))
            ?? (activeURLs.contains(url) ? .running : .incomplete)
        return RunLog(
            url: url,
            commandName: header.name,
            script: header.script,
            simulator: header.simulator,
            startedAt: header.startedAt,
            status: status
        )
    }

    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return formatter
    }()
}

/// What Settings shows about runs: the keep-last-N setting and a revision that changes whenever
/// runs start, finish, or are deleted.
@MainActor
final class RunLogStore: ObservableObject {
    static let shared = RunLogStore(
        directory: LogDirectory(
            root: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/SimShake", isDirectory: true)
        ),
        defaults: .standard
    )

    static let keepCountRange = 1...1000
    private static let keepCountKey = "logKeepCount"

    let directory: LogDirectory

    /// Applied when the command next runs, so lowering it doesn't delete anything right away.
    @Published var keepCount: Int {
        didSet {
            let clamped = Self.clamp(keepCount)
            if clamped != keepCount { keepCount = clamped }
            defaults.set(clamped, forKey: Self.keepCountKey)
        }
    }

    @Published private(set) var revision = 0

    private let defaults: UserDefaults

    init(directory: LogDirectory, defaults: UserDefaults) {
        self.directory = directory
        self.defaults = defaults
        keepCount = Self.clamp(defaults.object(forKey: Self.keepCountKey) as? Int ?? 50)
    }

    func logs(for commandID: UUID) -> [RunLog] {
        directory.logs(for: commandID, activeURLs: CommandRunner.activeLogURLs)
    }

    func clear(_ commandID: UUID) {
        directory.removeLogs(for: commandID)
        noteChange()
    }

    func removeLogs(for ids: some Sequence<UUID>) {
        ids.forEach(directory.removeLogs(for:))
        noteChange()
    }

    func noteChange() {
        revision += 1
    }

    private static func clamp(_ count: Int) -> Int {
        min(max(count, keepCountRange.lowerBound), keepCountRange.upperBound)
    }
}
