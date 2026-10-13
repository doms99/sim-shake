import AppKit
import UniformTypeIdentifiers

/// Asks for a command's `{{name}}` and `{name:file}` parameter values in a small modal dialog.
@MainActor
enum ParameterPrompt {
    /// The normalized values keyed by parameter name, or `nil` if the dialog was cancelled.
    static func ask(for command: Command, on simulator: Simulator?) -> [String: String]? {
        let parameters = command.parameters
        let alert = NSAlert()
        alert.messageText = command.name
        alert.informativeText = simulator?.menuTitle ?? ""
        let runButton = alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel") // NSAlert maps Escape to a button titled "Cancel".

        let fields = parameters.map { _ in
            let field = NSTextField(string: "")
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
            return field
        }
        for (field, next) in zip(fields, fields.dropFirst() + fields.prefix(1)) {
            field.nextKeyView = next
        }

        let validator = RequiredFields(fields: fields, button: runButton)
        fields.forEach { $0.delegate = validator }

        var choosers: [FileChooser] = []
        let rows: [[NSView]] = zip(parameters, fields).map { parameter, field in
            let label = NSTextField(labelWithString: "\(parameter.name):")
            guard case .file(let extensions) = parameter.kind else {
                return [label, field, NSGridCell.emptyContentView]
            }
            field.placeholderString = extensions.isEmpty ? "Path" : extensions.joined(separator: ", ")
            let chooser = FileChooser(name: parameter.name, extensions: extensions, field: field, window: alert.window, validator: validator)
            choosers.append(chooser)
            let button = NSButton(title: "Choose…", target: chooser, action: #selector(FileChooser.choose(_:)))
            button.keyEquivalent = ""
            // A third column rather than a stack view, so the grid aligns all three on the baseline.
            return [label, field, button]
        }

        let grid = NSGridView(views: rows)
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.layoutSubtreeIfNeeded()
        grid.setFrameSize(grid.fittingSize)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = fields.first
        validator.update()

        NSApp.activate(ignoringOtherApps: true)
        let response = withExtendedLifetime((validator, choosers)) { alert.runModal() }
        guard response == .alertFirstButtonReturn else { return nil }
        return Dictionary(uniqueKeysWithValues: zip(parameters, fields).map { parameter, field in
            (parameter.name, parameter.normalizedValue(field.stringValue))
        })
    }
}

/// Keeps the Run button disabled until every field has a value.
@MainActor
private final class RequiredFields: NSObject, NSTextFieldDelegate {
    private let fields: [NSTextField]
    private let button: NSButton

    init(fields: [NSTextField], button: NSButton) {
        self.fields = fields
        self.button = button
    }

    func update() {
        button.isEnabled = fields.allSatisfy { !$0.stringValue.trimmed.isEmpty }
    }

    func controlTextDidChange(_ notification: Notification) {
        update()
    }
}

/// Fills a file parameter's field from an open panel shown as a sheet on the dialog.
@MainActor
private final class FileChooser: NSObject {
    private let name: String
    private let extensions: [String]
    private let field: NSTextField
    private let window: NSWindow
    private let validator: RequiredFields

    init(name: String, extensions: [String], field: NSTextField, window: NSWindow, validator: RequiredFields) {
        self.name = name
        self.extensions = extensions
        self.field = field
        self.window = window
        self.validator = validator
    }

    @objc func choose(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = name
        // Filtering by type alone would also stop folders from being chosen.
        let types = extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = types.isEmpty ? [] : types + [.folder]
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let url = panel.url else { return }
            field.stringValue = url.path
            // Setting the value in code doesn't send `controlTextDidChange`.
            validator.update()
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
