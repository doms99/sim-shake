import Foundation

struct Command: Codable, Identifiable, Hashable {
    static let udidPlaceholder = "{udid}"

    var id = UUID()
    var name: String
    var command: String
    var symbol: String

    /// A value asked for before the command runs: `{{name}}` is typed text, `{name:file}` a path.
    struct Parameter: Hashable {
        enum Kind: Hashable {
            case text
            /// Lowercased, without leading dots; empty means any file or folder.
            case file(extensions: [String])
        }

        var name: String
        var kind: Kind

        /// Trims the entered value; file paths also get a leading `~` expanded, since the shell
        /// won't expand it inside quotes.
        func normalizedValue(_ raw: String) -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard case .file = kind else { return trimmed }
            return NSString(string: trimmed).expandingTildeInPath
        }
    }

    /// `{udid}` outside any `{{…}}` or `{…:file}` placeholder.
    var usesSimulator: Bool {
        tokens.contains { if case .udid = $0 { true } else { false } }
    }

    /// One entry per placeholder name, trimmed and in order of first appearance. A name used with
    /// `:file` anywhere is a file parameter; its extensions are the union of its `:file`
    /// placeholders, and any one without extensions lifts the filter.
    var parameters: [Parameter] {
        var names: [String] = []
        var kinds: [String: Parameter.Kind] = [:]
        for token in tokens {
            switch token {
            case .parameter(let name):
                if kinds[name] == nil {
                    names.append(name)
                    kinds[name] = .text
                }
            case .file(let name, let extensions):
                switch kinds[name] {
                case nil:
                    names.append(name)
                    kinds[name] = .file(extensions: extensions)
                case .text:
                    kinds[name] = .file(extensions: extensions)
                case .file(let existing):
                    let merged = existing.isEmpty || extensions.isEmpty
                        ? []
                        : existing + extensions.filter { !existing.contains($0) }
                    kinds[name] = .file(extensions: merged)
                }
            case .text, .udid:
                break
            }
        }
        return names.compactMap { name in kinds[name].map { Parameter(name: name, kind: $0) } }
    }

    /// Commands missing a name or a command are kept in Settings but hidden from the menu.
    var isRunnable: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Fills `{udid}` and each `{{name}}` and `{name:file}` (as one shell-quoted argument) in a
    /// single pass, so inserted text is never substituted again.
    func resolved(udid: String?, values: [String: String] = [:]) -> String {
        tokens.map { token in
            switch token {
            case .text(let text): text
            case .udid: udid ?? Self.udidPlaceholder
            case .parameter(let name), .file(let name, _): Self.shellQuoted(values[name] ?? "")
            }
        }
        .joined()
    }

    /// POSIX single-quoting: `it's` → `'it'\''s'`.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    private enum Token {
        case text(String)
        case udid
        case parameter(String)
        case file(name: String, extensions: [String])
    }

    /// Splits the command into literal text, `{udid}`, `{{name}}` and `{name:file}` /
    /// `{name:file:png,jpg}` placeholders. A placeholder with a blank name stays literal text.
    private var tokens: [Token] {
        var tokens: [Token] = []
        var cursor = command.startIndex
        for match in command.matches(of: #/\{\{([^{}]+)\}\}|\{udid\}|\{([^{}:]+):file(?::([^{}]*))?\}/#) {
            let literal = String(command[cursor..<match.range.lowerBound])
            cursor = match.range.upperBound
            if let rawName = match.output.1 ?? match.output.2 {
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.isEmpty {
                    tokens.append(.text(literal + match.output.0))
                    continue
                }
                if match.output.2 != nil {
                    let extensions = Self.fileExtensions(match.output.3.map(String.init) ?? "")
                    tokens.append(contentsOf: [.text(literal), .file(name: name, extensions: extensions)])
                } else {
                    tokens.append(contentsOf: [.text(literal), .parameter(name)])
                }
            } else {
                tokens.append(contentsOf: [.text(literal), .udid])
            }
        }
        tokens.append(.text(String(command[cursor...])))
        return tokens
    }

    /// `" .PNG, jpg,,png "` → `["png", "jpg"]`.
    private static func fileExtensions(_ list: String) -> [String] {
        var seen = Set<String>()
        return list.split(separator: ",").compactMap { item in
            var ext = item.trimmingCharacters(in: .whitespaces)
            while ext.hasPrefix(".") { ext.removeFirst() }
            ext = ext.lowercased()
            guard !ext.isEmpty, seen.insert(ext).inserted else { return nil }
            return ext
        }
    }
}

@MainActor
final class CommandStore: ObservableObject {
    private static let key = "commands"
    /// Set once Add Media has been offered, so deleting it keeps it deleted.
    private static let didAddMediaKey = "didAddMediaCommand"

    nonisolated static var defaultCommands: [Command] {
        [
            Command(
                name: "Shake",
                command: "xcrun simctl spawn {udid} notifyutil -p com.apple.UIKit.SimulatorShake",
                symbol: "iphone.gen3.radiowaves.left.and.right"
            ),
            addMediaCommand,
        ]
    }

    /// A fresh id on every access, like the rest of `defaultCommands`.
    private nonisolated static var addMediaCommand: Command {
        Command(
            name: "Add Media",
            command: "xcrun simctl addmedia {udid} {media:file:png,jpg,jpeg,heic,gif,mp4,mov,m4v}",
            symbol: "photo.on.rectangle"
        )
    }

    /// Removing a command (including through `restoreDefaults()`) deletes its logs.
    @Published var commands: [Command] {
        didSet {
            let removedIDs = Set(oldValue.map(\.id)).subtracting(commands.map(\.id))
            if !removedIDs.isEmpty {
                logs.removeLogs(for: removedIDs)
            }
            save()
        }
    }

    private let defaults: UserDefaults
    private let logs: RunLogStore

    init(defaults: UserDefaults = .standard, logs: RunLogStore = .shared) {
        self.defaults = defaults
        self.logs = logs
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Command].self, from: data) {
            commands = saved
            // Commands saved before Add Media existed get it appended once.
            if !defaults.bool(forKey: Self.didAddMediaKey) {
                commands.append(Self.addMediaCommand)
                save() // `didSet` doesn't run during init.
            }
        } else {
            commands = Self.defaultCommands
        }
        defaults.set(true, forKey: Self.didAddMediaKey)
    }

    func restoreDefaults() {
        commands = Self.defaultCommands
    }

    private func save() {
        do {
            defaults.set(try JSONEncoder().encode(commands), forKey: Self.key)
        } catch {
            NSLog("SimShake: failed to save commands: %@", error.localizedDescription)
        }
    }
}
