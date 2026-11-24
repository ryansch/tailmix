#if canImport(AppKit)
import AppKit
import ServiceManagement
import TailmixKit

/// Wraps an exit node choice for NSMenuItem.representedObject.
private final class ExitNodeBox: NSObject {
    let ref: ExitNodeRef
    init(_ ref: ExitNodeRef) { self.ref = ref }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let rememberedExitNodeKey = "LastExitNode"
    private static let socketDirectoryKey = "SocketDirectory"
    private static let backgroundRefreshInterval: TimeInterval = 10

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?
    private var menuIsOpen = false
    private var busy = false
    private var snapshot: Snapshot?
    private var lastError: Error?
    private var model = MenuModel.build(snapshot: nil, error: nil, currentUID: "", remembered: nil)
    private let currentUID = String(getuid())

    private var socketDirectory: String {
        if let configured = UserDefaults.standard.string(forKey: Self.socketDirectoryKey), !configured.isEmpty {
            return configured
        }
        if let env = ProcessInfo.processInfo.environment["TAILMIX_SOCKET_DIR"], !env.isEmpty {
            return env
        }
        return ControlClient.defaultSocketDirectory
    }

    /// Reads must not hold up the menu; profile starts can take longer.
    private var readClient: ControlClient { ControlClient(socketDirectory: socketDirectory, timeout: 2) }
    private var actionClient: ControlClient { ControlClient(socketDirectory: socketDirectory, timeout: 60) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refreshNow()
        timer = Timer.scheduledTimer(withTimeInterval: Self.backgroundRefreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInBackground() }
        }
    }

    // MARK: Refreshing

    private var rememberedExitNode: ExitNodeRef? {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.rememberedExitNodeKey) else { return nil }
            return try? JSONDecoder().decode(ExitNodeRef.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.rememberedExitNodeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.rememberedExitNodeKey)
            }
        }
    }

    /// Reads the daemon synchronously. Used right before the menu opens, so it
    /// never shows stale state; the socket is local and the timeout short.
    private func refreshNow() {
        do {
            apply(snapshot: try readClient.snapshot(), error: nil)
        } catch {
            apply(snapshot: nil, error: error)
        }
    }

    private func refreshInBackground() {
        let client = readClient
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try client.snapshot() }
            DispatchQueue.main.async {
                switch result {
                case .success(let snapshot): self.apply(snapshot: snapshot, error: nil)
                case .failure(let error): self.apply(snapshot: nil, error: error)
                }
            }
        }
    }

    private func apply(snapshot: Snapshot?, error: Error?) {
        self.snapshot = snapshot
        lastError = error
        if let selected = snapshot?.exitNodes.selected {
            let label = MenuModel.shortName(selected.dnsName, fallback: selected.nodeID)
            let ref = ExitNodeRef(profileName: selected.profileName, nodeID: selected.nodeID, label: label)
            if rememberedExitNode != ref { rememberedExitNode = ref }
        }
        let next = MenuModel.build(snapshot: snapshot, error: error, currentUID: currentUID, remembered: rememberedExitNode)
        updateIcon(next.icon)
        // Rebuilding an open menu would close the submenu being browsed.
        if next != model || menu.items.isEmpty {
            model = next
            if !menuIsOpen { rebuildMenu() }
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !busy else { return }
        refreshNow()
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        rebuildMenu()
    }

    // MARK: Building the menu

    private func updateIcon(_ state: IconState) {
        guard let button = statusItem.button else { return }
        let symbol: String
        let description: String
        switch state {
        case .unavailable:
            symbol = "exclamationmark.triangle"
            description = "tailmix is not running"
        case .disconnected:
            symbol = "network.slash"
            description = "tailmix is disconnected"
        case .connected:
            symbol = "network"
            description = "tailmix is connected"
        case .exitNode:
            symbol = "network.badge.shield.half.filled"
            description = "tailmix is using an exit node"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "network", accessibilityDescription: description)
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = state == .disconnected || state == .unavailable
        button.toolTip = model.headline
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let headline = NSMenuItem(title: model.headline, action: nil, keyEquivalent: "")
        headline.isEnabled = false
        menu.addItem(headline)
        if busy {
            menu.addItem(disabledItem("Working…"))
        }

        if !model.isDaemonReachable {
            if let lastError, !(lastError is TransportError) {
                menu.addItem(disabledItem("\(lastError)", indent: 1))
            } else {
                menu.addItem(disabledItem("Start it with: sudo launchctl kickstart system/io.github.maisem.tailmixd", indent: 1))
            }
        } else {
            if model.needsOperator {
                menu.addItem(.separator())
                let allow = NSMenuItem(title: "Allow \(NSUserName()) to Control tailmix…", action: #selector(authorizeOperator), keyEquivalent: "")
                allow.target = self
                allow.toolTip = model.operatorName.map { "The operator is currently \($0)." }
                    ?? "Connecting profiles and choosing exit nodes requires administrator approval once."
                menu.addItem(allow)
            }
            addProfiles()
            addExitNodes()
        }

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let quit = NSMenuItem(title: "Quit tailmix Menu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func addProfiles() {
        menu.addItem(.separator())
        menu.addItem(sectionHeader("Profiles"))
        if model.profiles.isEmpty {
            menu.addItem(disabledItem("Add one with: sudo tailmix profiles add <name>", indent: 1))
            return
        }
        for row in model.profiles {
            let item = NSMenuItem(title: row.name, action: #selector(toggleProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = row.name
            item.attributedTitle = titleWithDetail(row.name, row.detail)
            item.state = row.isOn ? .on : .off
            item.isEnabled = row.isActionable && !busy
            item.toolTip = row.errorMessage ?? (row.isOn ? "Click to disconnect \(row.name)" : "Click to connect \(row.name)")
            menu.addItem(item)
            if let url = row.loginURL {
                let login = NSMenuItem(title: "Log in to \(row.name)…", action: #selector(openURL(_:)), keyEquivalent: "")
                login.target = self
                login.representedObject = url
                login.indentationLevel = 1
                menu.addItem(login)
            }
        }
    }

    private func addExitNodes() {
        guard let section = model.exitNode else { return }
        menu.addItem(.separator())
        menu.addItem(sectionHeader("Exit Node"))

        let toggle = NSMenuItem(title: section.toggleTitle, action: #selector(toggleExitNode), keyEquivalent: "")
        toggle.target = self
        toggle.state = section.isOn ? .on : .off
        toggle.isEnabled = section.isToggleEnabled && !busy
        toggle.toolTip = section.isOn ? "Click to stop using the exit node" : "Click to use this exit node again"
        menu.addItem(toggle)
        if let note = section.note {
            menu.addItem(disabledItem(note, indent: 1))
        }

        let chooser = NSMenuItem(title: "Choose Exit Node", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let none = NSMenuItem(title: "None", action: #selector(clearExitNode), keyEquivalent: "")
        none.target = self
        none.state = section.isOn ? .off : .on
        none.isEnabled = !busy
        submenu.addItem(none)
        if section.groups.isEmpty {
            submenu.addItem(.separator())
            submenu.addItem(disabledItem("No connected profile offers an exit node"))
        }
        for group in section.groups {
            submenu.addItem(.separator())
            submenu.addItem(sectionHeader(group.profileName))
            for node in group.nodes {
                submenu.addItem(exitNodeItem(node))
            }
            for country in group.countries {
                let countryItem = NSMenuItem(title: country.name, action: nil, keyEquivalent: "")
                countryItem.state = country.containsSelection ? .mixed : .off
                let cities = NSMenu()
                cities.autoenablesItems = false
                for node in country.nodes {
                    cities.addItem(exitNodeItem(node))
                }
                countryItem.submenu = cities
                submenu.addItem(countryItem)
            }
        }
        chooser.submenu = submenu
        chooser.isEnabled = !busy
        menu.addItem(chooser)
    }

    private func exitNodeItem(_ node: ExitNodeChoice) -> NSMenuItem {
        let title = node.isOnline ? node.title : "\(node.title) (offline)"
        let item = NSMenuItem(title: title, action: #selector(selectExitNode(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ExitNodeBox(node.ref)
        item.state = node.isSelected ? .on : .off
        item.isEnabled = (node.isOnline || node.isSelected) && !busy
        return item
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    private func disabledItem(_ title: String, indent: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = indent
        return item
    }

    private func titleWithDetail(_ title: String, _ detail: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        result.append(NSAttributedString(string: "   \(detail)", attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return result
    }

    // MARK: Actions

    @objc private func toggleProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let row = model.profiles.first(where: { $0.name == name }) else { return }
        let connect = !row.isOn
        perform(connect ? "connect \(name)" : "disconnect \(name)") { client in
            try client.setProfileConnected(name, connect)
        }
    }

    @objc private func toggleExitNode() {
        guard let section = model.exitNode else { return }
        if section.isOn {
            clearExitNode()
        } else if let target = section.toggleTarget {
            perform("use exit node \(target.label)") { client in
                try client.setExitNode(profileName: target.profileName, nodeID: target.nodeID)
            }
        }
    }

    @objc private func selectExitNode(_ sender: NSMenuItem) {
        guard let ref = (sender.representedObject as? ExitNodeBox)?.ref else { return }
        perform("use exit node \(ref.label)") { client in
            try client.setExitNode(profileName: ref.profileName, nodeID: ref.nodeID)
        }
    }

    @objc private func clearExitNode() {
        perform("stop using the exit node") { client in
            try client.clearExitNode()
        }
    }

    @objc private func openURL(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showError("Could not change Open at Login", error)
        }
        rebuildMenu()
    }

    /// Runs a mutation off the main thread, then refreshes.
    private func perform(_ description: String, _ action: @escaping (ControlClient) throws -> Void) {
        guard !busy else { return }
        busy = true
        rebuildMenu()
        let client = actionClient
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try action(client) }
            DispatchQueue.main.async {
                self.busy = false
                if case .failure(let error) = result {
                    if let apiError = error as? APIError, apiError.isPermissionDenied {
                        self.offerOperator(after: description)
                    } else {
                        self.showError("Could not \(description)", error)
                    }
                }
                self.refreshNow()
                self.rebuildMenu()
            }
        }
    }

    // MARK: Operator

    private func offerOperator(after description: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Could not \(description)"
        alert.informativeText = "tailmix only accepts changes from root or its operator. Make \(NSUserName()) the operator to connect profiles and choose exit nodes from this menu. You will be asked for an administrator password once."
        alert.addButton(withTitle: "Allow \(NSUserName())")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            authorizeOperator()
        }
    }

    @objc private func authorizeOperator() {
        let candidates = ["/usr/local/bin/tailmix", "/opt/homebrew/bin/tailmix"]
        guard let cli = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            showError("Could not find the tailmix command",
                      TransportError("Looked in \(candidates.joined(separator: " and ")). Run: sudo tailmix operator set \(NSUserName())"))
            return
        }
        // The command is built from a fixed path and a numeric uid only.
        let command = "'\(cli)' operator set \(currentUID)"
        let source = "do shell script \"\(command)\" with administrator privileges"
        var errorInfo: NSDictionary?
        NSApp.activate(ignoringOtherApps: true)
        NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        if let errorInfo, (errorInfo[NSAppleScript.errorNumber] as? Int) != -128 {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown error"
            showError("Could not make \(NSUserName()) the operator", TransportError(message))
        }
        refreshNow()
        rebuildMenu()
    }

    private func showError(_ title: String, _ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = "\(error)"
        alert.runModal()
    }
}
#endif
