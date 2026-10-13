import Foundation
import os

enum CommandRunner {
    private struct Registry {
        var processes: [ObjectIdentifier: Process] = [:]
        /// Kept until the footer is written, which is after the process leaves `processes`.
        var writers: [ObjectIdentifier: RunLogWriter] = [:]
        var isTerminating = false
    }

    private static let registry = OSAllocatedUnfairLock(initialState: Registry())

    /// Log files of runs that haven't written their footer yet.
    static var activeLogURLs: Set<URL> {
        registry.withLock { Set($0.writers.values.map(\.url)) }
    }

    /// Runs the command through the user's login shell off the main thread, logging its output to
    /// its own file; only failures are reported.
    @MainActor
    static func run(_ command: Command, on simulator: Simulator? = nil, values: [String: String] = [:]) {
        let run = Run(
            commandID: command.id,
            name: command.name,
            script: command.resolved(udid: simulator?.udid, values: values),
            subtitle: simulator?.menuTitle,
            directory: RunLogStore.shared.directory,
            keepCount: RunLogStore.shared.keepCount
        )
        DispatchQueue.global(qos: .userInitiated).async {
            execute(run)
        }
    }

    private struct Run: Sendable {
        var commandID: UUID
        var name: String
        var script: String
        /// The simulator's menu title, if the command targets one.
        var subtitle: String?
        var directory: LogDirectory
        var keepCount: Int
    }

    private static let loginShell: String = {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }()

    private static func execute(_ run: Run) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShell)
        process.arguments = ["-l", "-c", run.script]
        // Resolved here, off the main thread, so `xcrun` in commands uses the same Xcode as the menu.
        // A `DEVELOPER_DIR` exported in the login profile still wins.
        process.environment = XcodeSelector.environment(for: XcodeSelector.current().developerDirectory)
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let writer = run.directory.startRun(
            commandID: run.commandID,
            commandName: run.name,
            script: run.script,
            simulator: run.subtitle,
            startedAt: Date()
        )
        // Registered before launch so the termination handler always finds it.
        let key = ObjectIdentifier(process)
        if let writer {
            registry.withLock { $0.writers[key] = writer }
        }
        let tail = OutputTail(limit: 2048)
        let reachedEOF = DispatchSemaphore(value: 0)
        // The handler retains the reader until EOF, so output from a still-running command keeps draining.
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { _ in
            let data = reader.availableData
            if data.isEmpty {
                reader.readabilityHandler = nil
                reachedEOF.signal()
            } else {
                tail.append(data)
                writer?.append(data)
            }
        }

        process.terminationHandler = { process in
            let isTerminating = registry.withLock { registry in
                registry.processes[key] = nil
                return registry.isTerminating
            }
            // Let buffered output arrive, but don't wait on background children that keep the pipe open.
            _ = reachedEOF.wait(timeout: .now() + 1)
            let status = process.terminationStatus
            if let writer {
                writer.finish(isTerminating ? .stopped : .exited(status))
                registry.withLock { _ = $0.writers.removeValue(forKey: key) }
                noteLogsChanged()
            }
            // Commands stopped because SimShake is quitting aren't failures.
            guard status != 0, !isTerminating else { return }
            let output = tail.text.trimmingCharacters(in: .whitespacesAndNewlines)
            report(name: run.name, subtitle: run.subtitle, body: output.isEmpty ? "Exited with status \(status)" : output)
        }

        do {
            try process.run()
        } catch {
            reader.readabilityHandler = nil
            if let writer {
                writer.finish(.launchFailed(error.localizedDescription))
                registry.withLock { _ = $0.writers.removeValue(forKey: key) }
                noteLogsChanged()
            }
            report(name: run.name, subtitle: run.subtitle, body: error.localizedDescription)
            return
        }
        register(process)
        if writer != nil {
            run.directory.prune(commandID: run.commandID, keep: run.keepCount, excluding: activeLogURLs)
            noteLogsChanged()
        }
    }

    private static func register(_ process: Process) {
        let key = ObjectIdentifier(process)
        let (isTerminating, writer) = registry.withLock { registry in
            registry.processes[key] = process
            return (registry.isTerminating, registry.writers[key])
        }
        if isTerminating {
            terminate(process)
            writer?.finish(.stopped)
        }
        // Its termination handler may have run before registration; don't leave an exited command behind.
        if !process.isRunning {
            registry.withLock { _ = $0.processes.removeValue(forKey: key) }
        }
    }

    /// Sends SIGTERM to every running command and everything it started, without waiting for them to
    /// exit, and marks their logs stopped right away since SimShake exits before their handlers run.
    static func terminateAll() {
        let (processes, writers) = registry.withLock { registry in
            registry.isTerminating = true
            return (Array(registry.processes.values), Array(registry.writers.values))
        }
        processes.forEach(terminate)
        writers.forEach { $0.finish(.stopped) }
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        // Process starts each child as its own process-group leader, so signalling the group also
        // reaches the commands the shell started. Fall back to the shell alone if that ever changes.
        if kill(-pid, SIGTERM) != 0 {
            kill(pid, SIGTERM)
        }
    }

    private static func noteLogsChanged() {
        Task { @MainActor in
            RunLogStore.shared.noteChange()
        }
    }

    private static func report(name: String, subtitle: String?, body: String) {
        Task { @MainActor in
            Notifier.shared.post(title: "\(name) failed", subtitle: subtitle, body: body)
        }
    }
}

/// Keeps only the last `limit` bytes of output so endlessly printing commands don't grow memory.
private final class OutputTail: Sendable {
    private let limit: Int
    private let buffer = OSAllocatedUnfairLock(initialState: Data())

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ data: Data) {
        buffer.withLock { [limit] buffer in
            buffer.append(data)
            if buffer.count > limit {
                buffer = Data(buffer.suffix(limit))
            }
        }
    }

    var text: String {
        let data = buffer.withLock { $0 }
        // Truncation may have split a UTF-8 sequence; skip leading continuation bytes.
        let start = data.firstIndex { $0 & 0xC0 != 0x80 } ?? data.endIndex
        return String(decoding: data[start...], as: UTF8.self)
    }
}
