import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: CommandStore
    @ObservedObject var logs: RunLogStore
    @State private var selection: Command.ID?
    @State private var isConfirmingRestore = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 220)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Button("Restore Defaults…") { isConfirmingRestore = true }
                Spacer()
                Stepper(
                    "Keep last \(logs.keepCount) logs per command",
                    value: $logs.keepCount,
                    in: RunLogStore.keepCountRange
                )
            }
            .padding(12)
        }
        .frame(minWidth: 600, idealWidth: 680, minHeight: 380, idealHeight: 440)
        .onAppear {
            if selection == nil { selection = store.commands.first?.id }
        }
        .alert("Restore Defaults?", isPresented: $isConfirmingRestore) {
            Button("Restore Defaults", role: .destructive) {
                store.restoreDefaults()
                selection = store.commands.first?.id
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces all commands with the default Shake command.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.commands) { command in
                    Label {
                        Text(command.name.isEmpty ? "Untitled" : command.name)
                    } icon: {
                        SymbolImage(name: command.symbol)
                    }
                }
                .onMove { store.commands.move(fromOffsets: $0, toOffset: $1) }
            }
            Divider()
            HStack(spacing: 0) {
                Button(action: addCommand) {
                    Image(systemName: "plus").frame(width: 24, height: 22)
                }
                .help("Add Command")
                Button(action: removeSelectedCommand) {
                    Image(systemName: "minus").frame(width: 24, height: 22)
                }
                .help("Remove Command")
                .disabled(selection == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(4)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selection, let command = binding(for: id) {
            CommandEditor(command: command, logs: logs)
                .id(id)
        } else {
            Text(store.commands.isEmpty ? "Click + to add a command." : "Select a command.")
                .foregroundStyle(.secondary)
        }
    }

    /// Looks the command up by id on every access, so deleting it can't leave a stale index binding.
    private func binding(for id: Command.ID) -> Binding<Command>? {
        guard let current = store.commands.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { store.commands.first { $0.id == id } ?? current },
            set: { newValue in
                if let index = store.commands.firstIndex(where: { $0.id == id }) {
                    store.commands[index] = newValue
                }
            }
        )
    }

    private func addCommand() {
        let command = Command(name: "New Command", command: "", symbol: "terminal")
        store.commands.append(command)
        selection = command.id
    }

    private func removeSelectedCommand() {
        guard let id = selection, let index = store.commands.firstIndex(where: { $0.id == id }) else { return }
        store.commands.remove(at: index)
        selection = store.commands.indices.contains(index) ? store.commands[index].id : store.commands.last?.id
    }
}

private struct CommandEditor: View {
    private static let curatedSymbols = [
        "iphone.gen3.radiowaves.left.and.right", "terminal", "bolt", "arrow.clockwise", "ladybug",
        "hammer", "hand.wave", "hand.tap", "camera", "trash",
        "play", "stop", "link", "globe", "keyboard",
        "bell", "location", "photo", "doc.on.clipboard", "folder",
        "gearshape", "wrench.and.screwdriver", "paintbrush", "moon", "lock",
        "network", "speaker.wave.2", "square.and.arrow.up", "record.circle", "exclamationmark.triangle",
    ]

    @Binding var command: Command
    @ObservedObject var logs: RunLogStore
    @State private var runs: [RunLog] = []
    @State private var hasLogFolder = false
    @State private var isConfirmingClear = false

    private var logFolder: URL { logs.directory.folder(for: command.id) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $command.name)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Command")
                    CommandTextView(text: $command.command)
                        .frame(height: 80)
                    Text("Include `{udid}` to pick a booted simulator, `{{name}}` for a value you enter each time it runs, and `{name:file}` or `{name:file:png,jpg}` for a file or folder you pick (each inserted as one quoted argument).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !command.parameters.isEmpty {
                        Text("Asks for: \(command.parameters.map(Self.describe).joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !command.isRunnable {
                        Text("Commands without a name or command are hidden from the menu.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Icon") {
                HStack(alignment: .top, spacing: 12) {
                    SymbolImage(name: command.symbol)
                        .font(.system(size: 26))
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("SF Symbol", text: $command.symbol, prompt: Text("Any SF Symbol name"))
                        if !SymbolImage.isValid(command.symbol) {
                            Text("No SF Symbol with this name. The menu will show a terminal icon.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 32), spacing: 6)], spacing: 6) {
                    ForEach(Self.curatedSymbols, id: \.self) { name in
                        Button {
                            command.symbol = name
                        } label: {
                            Image(systemName: name)
                                .frame(width: 32, height: 28)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(command.symbol == name ? Color.accentColor.opacity(0.25) : Color.clear)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(name)
                    }
                }
            }

            Section {
                if runs.isEmpty {
                    Text("No runs yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(runs) { run in
                        RunLogRow(log: run) { open(run) }
                    }
                }
            } header: {
                HStack {
                    Text("Logs")
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.open(logFolder) }
                        .disabled(!hasLogFolder)
                    Button("Clear…") { isConfirmingClear = true }
                        .disabled(runs.isEmpty)
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reloadRuns)
        .onChange(of: logs.revision) { _ in reloadRuns() }
        // Picks up files deleted in Finder when the window comes back to the front.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in reloadRuns() }
        .alert("Delete all logs for \(command.name.isEmpty ? "Untitled" : command.name)?", isPresented: $isConfirmingClear) {
            Button("Delete Logs", role: .destructive) { logs.clear(command.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the log files of every run of this command.")
        }
    }

    private func reloadRuns() {
        runs = logs.logs(for: command.id)
        hasLogFolder = FileManager.default.fileExists(atPath: logFolder.path)
    }

    /// Opens the file with the default app for `.log`; a file that's gone drops out of the list.
    private func open(_ run: RunLog) {
        if !NSWorkspace.shared.open(run.url) {
            reloadRuns()
        }
    }

    /// `url`, or `media (file)` for a file parameter.
    private static func describe(_ parameter: Command.Parameter) -> String {
        guard case .file = parameter.kind else { return parameter.name }
        return "\(parameter.name) (file)"
    }
}

private struct RunLogRow: View {
    let log: RunLog
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 8) {
                statusIcon
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        title
                            .lineLimit(1)
                        Spacer()
                        Text(log.startedAt.formatted(date: .abbreviated, time: .standard))
                            .foregroundStyle(.secondary)
                    }
                    Text(log.script)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(log.script)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open", action: open)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([log.url]) }
        }
    }

    private var title: Text {
        guard let simulator = log.simulator else { return Text(log.commandName) }
        return Text(log.commandName) + Text(" · \(simulator)").foregroundColor(.secondary)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch log.status {
        case .running:
            ProgressView()
                .controlSize(.small)
                .help("Running")
        case .exited(0):
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("Finished")
        case .exited(let status):
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .help("Exited with status \(status)")
        case .launchFailed(let error):
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .help("Failed to start: \(error)")
        case .stopped:
            Image(systemName: "stop.circle")
                .foregroundStyle(.secondary)
                .help("Stopped when SimShake quit")
        case .incomplete:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
                .help("Incomplete: SimShake quit before it finished")
        }
    }
}

/// Renders an SF Symbol by name, with a placeholder for names that don't exist.
private struct SymbolImage: View {
    var name: String

    static func isValid(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    var body: some View {
        if Self.isValid(name) {
            Image(systemName: name)
        } else {
            Image(systemName: "questionmark.square.dashed")
                .foregroundStyle(.secondary)
        }
    }
}

/// Plain monospaced text editor. SwiftUI's `TextEditor` applies smart quotes and dashes,
/// which would silently break shell commands (`"` → `“`, `--` → `—`).
private struct CommandTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .bezelBorder
        let textView = scrollView.documentView as! NSTextView
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.string = text
        textView.delegate = context.coordinator
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        let textView = scrollView.documentView as! NSTextView
        if textView.string != text {
            textView.string = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
