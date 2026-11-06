import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let statusSymbol = "iphone.gen3.radiowaves.left.and.right"
    private static let didRegisterLoginItemKey = "didRegisterLoginItem"

    private let store = CommandStore()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var terminationSignalSource: DispatchSourceSignal?
    /// Result of the latest simulator listing; `nil` until the first one finishes.
    private var bootedSimulators: BootedSimulators?
    private var isRefreshingSimulators = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTerminationSignalHandler()
        installMainMenu()
        installStatusItem()
        refreshSimulators()
        Notifier.shared.requestAuthorization()
        registerLoginItemIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        CommandRunner.terminateAll()
    }

    /// SIGTERM (e.g. `pkill` in build.sh) would otherwise exit without `applicationWillTerminate`,
    /// leaving started commands running. Commands still get the default SIGTERM action: Process
    /// resets signal dispositions in the children it spawns.
    private func installTerminationSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        source.resume()
        terminationSignalSource = source
    }

    // MARK: - Status item menu

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            // The bundled glyph from build.sh; the SF Symbol covers runs outside the app bundle (`swift run`).
            button.image = NSImage(named: "MenuBarIcon")
                ?? NSImage(systemSymbolName: Self.statusSymbol, accessibilityDescription: "SimShake")
            button.image?.isTemplate = true
            button.setAccessibilityLabel("SimShake")
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Whether a simulator command gets a submenu depends on how many simulators are booted, so the
        // menu is built from the last listing (instant) and rebuilt in place if a fresh one differs.
        if store.commands.contains(where: { $0.isRunnable && $0.usesSimulator }) {
            if bootedSimulators == nil {
                bootedSimulators = Self.listBootedSimulators()
            } else {
                refreshSimulators()
            }
        }
        populate(menu)
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        for command in store.commands where command.isRunnable {
            // The ellipsis marks commands that ask for input before running.
            let title = command.parameters.isEmpty ? command.name : command.name + "…"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = .symbol(command.symbol, fallback: "terminal")
            if command.usesSimulator {
                configureSimulatorItem(item, for: command)
            } else {
                item.action = #selector(runCommand(_:))
                item.target = self
                item.representedObject = command
            }
            menu.addItem(item)
        }
        if menu.numberOfItems > 0 {
            menu.addItem(.separator())
        }

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.target = self
        settings.image = .symbol("gearshape", fallback: "gear")
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        quit.image = .symbol("power", fallback: "xmark.circle")
        menu.addItem(quit)
    }

    /// Several booted simulators get a submenu; exactly one runs directly; none (or a failed
    /// listing) leaves the item disabled, since it has no action.
    private func configureSimulatorItem(_ item: NSMenuItem, for command: Command) {
        switch bootedSimulators ?? .listed([]) {
        case .failed(let reason):
            item.toolTip = reason
        case .listed(let simulators) where simulators.isEmpty:
            item.toolTip = "No booted simulators"
        case .listed(let simulators) where simulators.count == 1:
            item.action = #selector(runOnSimulator(_:))
            item.target = self
            item.representedObject = SimulatorRun(command: command, simulator: simulators[0])
            item.toolTip = "Runs on \(simulators[0].menuTitle)"
        case .listed(let simulators):
            let submenu = NSMenu(title: command.name)
            for simulator in simulators {
                let simulatorItem = NSMenuItem(title: simulator.menuTitle, action: #selector(runOnSimulator(_:)), keyEquivalent: "")
                simulatorItem.target = self
                simulatorItem.representedObject = SimulatorRun(command: command, simulator: simulator)
                simulatorItem.image = .symbol(simulator.symbolName, fallback: "iphone")
                submenu.addItem(simulatorItem)
            }
            item.submenu = submenu
        }
    }

    /// Lists simulators off the main thread and rebuilds the menu (even while it's open) if they changed.
    private func refreshSimulators() {
        guard !isRefreshingSimulators else { return }
        isRefreshingSimulators = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { Self.listBootedSimulators() }.value
            isRefreshingSimulators = false
            guard result != bootedSimulators else { return }
            bootedSimulators = result
            if let menu = statusItem?.menu {
                populate(menu)
            }
        }
    }

    /// Resolves the Xcode on every listing, so a changed choice shows up the next time the menu opens.
    private nonisolated static func listBootedSimulators() -> BootedSimulators {
        guard let developerDirectory = XcodeSelector.current().developerDirectory else {
            return .failed("No Xcode found. Install Xcode or choose one in Settings.")
        }
        do {
            return .listed(try Simulator.listBooted(developerDirectory: developerDirectory))
        } catch {
            NSLog("SimShake: couldn't list simulators: %@", error.localizedDescription)
            return .failed("Couldn't list simulators")
        }
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? Command else { return }
        run(command, on: nil)
    }

    @objc private func runOnSimulator(_ sender: NSMenuItem) {
        guard let run = sender.representedObject as? SimulatorRun else { return }
        self.run(run.command, on: run.simulator)
    }

    /// Commands with `{{name}}` or `{name:file}` parameters ask for their values first; cancelling
    /// runs nothing.
    private func run(_ command: Command, on simulator: Simulator?) {
        guard !command.parameters.isEmpty else {
            CommandRunner.run(command, on: simulator)
            return
        }
        // Menu actions run after the menu has closed, while the click is being handled, which is where
        // a modal dialog belongs. Deferring it to a run loop block or a main-queue block instead nests
        // the dialog inside AppKit's event fetch: the window server then treats SimShake as unresponsive
        // (spinning cursor, delayed clicks and keystrokes) for as long as the dialog is open.
        guard let values = ParameterPrompt.ask(for: command, on: simulator) else { return }
        CommandRunner.run(command, on: simulator, values: values)
    }

    // MARK: - Settings

    @objc private func openSettings(_ sender: Any?) {
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        // `activate()` is cooperative and is usually refused while another app is frontmost, which
        // left an already-open window behind other apps; this variant activates regardless.
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store, logs: .shared, xcode: .shared)))
        window.title = "SimShake Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 440))
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    /// Accessory apps have no visible menu bar, but key equivalents (⌘C, ⌘V, ⌘W, …) still route
    /// through the main menu, so Settings text fields need one.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "SimShake")
        mainMenu.addItem(appItem)

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileItem = NSMenuItem()
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Login item

    private func registerLoginItemIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didRegisterLoginItemKey) else { return }
        guard isInstalledInApplications else {
            NSLog("SimShake: not in an Applications folder, skipping login item registration (%@)", Bundle.main.bundlePath)
            return
        }
        let service = SMAppService.mainApp
        do {
            try service.register()
            defaults.set(true, forKey: Self.didRegisterLoginItemKey)
            NSLog("SimShake: registered login item, status: %@", describe(service.status))
        } catch {
            NSLog("SimShake: login item registration failed: %@ (status: %@)", error.localizedDescription, describe(service.status))
        }
    }

    private var isInstalledInApplications: Bool {
        let bundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let folders = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/Applications"),
        ]
        return folders.contains { bundlePath.hasPrefix($0.resolvingSymlinksInPath().path + "/") }
    }

    private func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown (\(status.rawValue))"
        }
    }
}

private enum BootedSimulators: Equatable {
    case listed([Simulator])
    /// Carries the disabled item's tooltip.
    case failed(String)
}

private struct SimulatorRun {
    let command: Command
    let simulator: Simulator
}

extension NSImage {
    /// An SF Symbol image, or `fallback` when `name` isn't a known symbol.
    static func symbol(_ name: String, fallback: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: nil)
    }
}
