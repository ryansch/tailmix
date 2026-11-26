#if canImport(AppKit)
import AppKit
import ServiceManagement
import TailmixKit
@preconcurrency import UserNotifications

/// Wraps an exit node choice for NSMenuItem.representedObject.
private final class ExitNodeBox: NSObject {
    let ref: ExitNodeRef
    init(_ ref: ExitNodeRef) { self.ref = ref }
}

/// Wraps a routes override choice for NSMenuItem.representedObject, so the
/// action uses the direction the clicked item showed.
private final class RoutesOverrideBox: NSObject {
    let profile: String
    let routes: String
    init(profile: String, routes: String) {
        self.profile = profile
        self.routes = routes
    }
}

/// Draws the menu bar icon: one rounded badge per profile.
private enum BadgeIcon {
    // Tall enough to centre the badge with room for the routes bar below it.
    static let height: CGFloat = 18
    static let badgeHeight: CGFloat = 12
    static let minBadgeWidth: CGFloat = 12
    static let spacing: CGFloat = 2
    static let barHeight: CGFloat = 2
    static let lineWidth: CGFloat = 1.3
    static let cornerRadius: CGFloat = 3
    static let font = NSFont.systemFont(ofSize: 9.5, weight: .bold)
    /// The amber dot on a badge whose key expires soon.
    static let expiringDotDiameter: CGFloat = 4.5
    /// The amber dot with "!" on a badge that needs sign-in.
    static let signInDotDiameter: CGFloat = 6.5
    /// The clear ring that separates a dot from the badge under it.
    static let dotGap: CGFloat = 1
    static let bangFont = NSFont.systemFont(ofSize: 6, weight: .black)

    /// A template image unless a badge shows an error or a sign-in mark;
    /// then the colours are fixed, resolved against the menu bar's appearance.
    static func image(_ badges: [ProfileBadge], appearance: NSAppearance, description: String) -> NSImage {
        let hasColor = badges.contains { $0.error || $0.expiringSoon || $0.needsSignIn }
        var normal = NSColor.black.cgColor
        var warning = NSColor.black.cgColor
        if hasColor {
            appearance.performAsCurrentDrawingAppearance {
                normal = NSColor.labelColor.cgColor
                warning = NSColor.systemOrange.cgColor
            }
        }
        let widths = badges.map(badgeWidth)
        var rects: [NSRect] = []
        var x: CGFloat = 0
        for badgeWidth in widths {
            rects.append(NSRect(x: x, y: (height - badgeHeight) / 2, width: badgeWidth, height: badgeHeight))
            x += badgeWidth + spacing
        }
        // Room for the last badge's mark, which overhangs its right edge,
        // rounded up to whole points so the badges stay on the pixel grid.
        let overhang = badges.last.flatMap(markDiameter).map { $0 / 2 } ?? 0
        let width = max(ceil((rects.last?.maxX ?? 0) + overhang), 1)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // The knocked-out labels clear only this layer, not what is behind the image.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            for (badge, rect) in zip(badges, rects) {
                draw(badge, in: rect, color: badge.error ? warning : normal, context: context)
            }
            // Marks go on top, so a mark's gap also clears the next badge's edge.
            for (badge, rect) in zip(badges, rects) {
                drawMark(badge, on: rect, color: warning, context: context)
            }
            context.endTransparencyLayer()
            return true
        }
        image.isTemplate = !hasColor
        image.accessibilityDescription = description
        return image
    }

    /// For example "home connected, routes on; work off".
    static func accessibilityDescription(_ badges: [ProfileBadge], names: [String]) -> String {
        let parts = badges.enumerated().map { index, badge in
            let name = index < names.count ? names[index] : badge.label
            var state = badge.connected ? "connected, routes \(badge.routes ? "on" : "off")" : "off"
            if badge.error { state += ", error" }
            if badge.needsSignIn {
                state += ", needs sign-in"
            } else if badge.expiringSoon {
                state += ", key expires soon"
            }
            return "\(name) \(state)"
        }
        return parts.isEmpty ? "tailmix" : "tailmix: " + parts.joined(separator: "; ")
    }

    private static func label(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
    }

    private static func badgeWidth(_ badge: ProfileBadge) -> CGFloat {
        max(minBadgeWidth, ceil(label(badge.label).size().width) + 6)
    }

    /// Draws text in the context's fill colour with its ink centred in rect.
    /// Centring the glyphs' own bounds, not the font's line box, keeps the
    /// letters clear of the badge's top edge (the line box is taller than
    /// ascender plus descender).
    private static func drawLabel(_ text: String, centredIn rect: NSRect, font: NSFont = font, context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = .zero
        let ink = CTLineGetImageBounds(line, context)
        context.textPosition = CGPoint(x: rect.midX - ink.midX, y: rect.midY - ink.midY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func draw(_ badge: ProfileBadge, in rect: NSRect, color: CGColor, context: CGContext) {
        context.setFillColor(color)
        context.setStrokeColor(color)
        if badge.connected {
            context.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
            context.fillPath()
            context.saveGState()
            context.setBlendMode(.destinationOut)
            drawLabel(badge.label, centredIn: rect, context: context)
            context.restoreGState()
        } else {
            let inset = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let radius = cornerRadius - lineWidth / 2
            context.setLineWidth(lineWidth)
            context.addPath(CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.strokePath()
            drawLabel(badge.label, centredIn: rect, context: context)
        }
        if badge.routes {
            let bar = NSRect(x: rect.minX + 2, y: 0, width: rect.width - 4, height: barHeight)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil))
            context.fillPath()
        }
    }

    /// The mark's diameter: needs sign-in wins over expiring soon.
    private static func markDiameter(_ badge: ProfileBadge) -> CGFloat? {
        if badge.needsSignIn { return signInDotDiameter }
        if badge.expiringSoon { return expiringDotDiameter }
        return nil
    }

    /// Draws the amber dot centred on the badge's top-right corner, moved
    /// down just enough to stay inside the image, with a clear ring around it
    /// and, for needs sign-in, a knocked-out "!".
    private static func drawMark(_ badge: ProfileBadge, on rect: NSRect, color: CGColor, context: CGContext) {
        guard let diameter = markDiameter(badge) else { return }
        let radius = diameter / 2
        let centre = CGPoint(x: rect.maxX, y: min(rect.maxY, height - radius))
        let dot = CGRect(x: centre.x - radius, y: centre.y - radius, width: diameter, height: diameter)
        context.saveGState()
        context.setBlendMode(.destinationOut)
        context.fillEllipse(in: dot.insetBy(dx: -dotGap, dy: -dotGap))
        context.restoreGState()
        context.setFillColor(color)
        context.fillEllipse(in: dot)
        if badge.needsSignIn {
            context.saveGState()
            context.setBlendMode(.destinationOut)
            drawLabel("!", centredIn: dot, font: bangFont, context: context)
            context.restoreGState()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private static let rememberedExitNodeKey = "LastExitNode"
    private static let sentNotificationsKey = "signInNotificationsSent"
    private static let socketDirectoryKey = "SocketDirectory"
    private static let backgroundRefreshInterval: TimeInterval = 10

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?
    private var menuIsOpen = false
    /// What the status item currently shows, so refreshes skip no-op updates.
    private var shownIcon: IconState?
    private var shownAppearance: NSAppearance.Name?
    private var shownNames: [String] = []
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

    /// The notification delegate must be set before launch finishes, so a
    /// click on a notification that launched the app is delivered.
    func applicationWillFinishLaunching(_ notification: Notification) {
        notificationCenter?.delegate = self
    }

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
        if let snapshot {
            notifySignIn(snapshot.status.profiles)
        }
        let next = MenuModel.build(snapshot: snapshot, error: error, currentUID: currentUID, remembered: rememberedExitNode)
        updateIcon(next)
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

    /// Updates the status item only when something visible changed. The item
    /// has no tooltip; the image's accessibility description names each
    /// profile's state instead.
    private func updateIcon(_ next: MenuModel) {
        guard let button = statusItem.button else { return }
        let appearance = button.effectiveAppearance.name
        let names = next.profiles.map(\.name)
        guard next.icon != shownIcon || appearance != shownAppearance || names != shownNames else { return }
        shownIcon = next.icon
        shownAppearance = appearance
        shownNames = names
        switch next.icon {
        case .unavailable:
            button.image = symbolImage("exclamationmark.triangle", description: "tailmix is not running")
            button.appearsDisabled = true
        case .paused:
            button.image = symbolImage("pause.circle", description: "tailmix is paused")
            button.appearsDisabled = true
        case .badges(let badges) where badges.isEmpty:
            // An empty badge image would leave nothing to click.
            button.image = symbolImage("network", description: "tailmix: no profiles")
            button.appearsDisabled = false
        case .badges(let badges):
            button.image = BadgeIcon.image(
                badges, appearance: button.effectiveAppearance,
                description: BadgeIcon.accessibilityDescription(badges, names: names))
            button.appearsDisabled = false
        }
    }

    private func symbolImage(_ symbol: String, description: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "network", accessibilityDescription: description)
        image?.isTemplate = true
        return image
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
            } else if row.waitingForLogin {
                let title = "Waiting for sign-in link…"
                let waiting = disabledItem(title, indent: Self.locationIndent)
                waiting.attributedTitle = locationTitle(title, color: nil)
                menu.addItem(waiting)
            }
            if let location = row.location {
                addLocationItems(location, for: row)
            }
        }
    }

    /// Location items sit deeper and smaller than profile rows so they read
    /// as belonging to the profile above them.
    private static let locationIndent = 2

    private func locationTitle(_ title: String, color: NSColor?) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)]
        if let color { attributes[.foregroundColor] = color }
        return NSAttributedString(string: title, attributes: attributes)
    }

    private func addLocationItems(_ location: LocationRow, for row: ProfileRow) {
        let detail = disabledItem(location.detail, indent: Self.locationIndent)
        detail.attributedTitle = locationTitle(location.detail, color: .secondaryLabelColor)
        menu.addItem(detail)
        var overrideBox: RoutesOverrideBox?
        if let routes = location.overrideRoutes {
            overrideBox = RoutesOverrideBox(profile: row.name, routes: routes)
        }
        let actions: [(String?, Selector, Any?)] = [
            (location.markTitle, #selector(markNetworkHome(_:)), row.name),
            (location.forgetTitle, #selector(forgetNetwork(_:)), row.name),
            (location.overrideTitle, #selector(overrideRoutes(_:)), overrideBox),
            (location.clearOverrideTitle, #selector(clearRoutesOverride(_:)), row.name),
        ]
        for case let (title?, action, represented) in actions {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = represented
            item.indentationLevel = Self.locationIndent
            item.attributedTitle = locationTitle(title, color: nil)
            item.isEnabled = row.isActionable && !busy
            menu.addItem(item)
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

    @objc private func markNetworkHome(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        perform("mark this network as home for \(name)") { client in
            _ = try client.markCurrentNetworkHome(name)
        }
    }

    @objc private func forgetNetwork(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        perform("forget this network for \(name)") { client in
            _ = try client.forgetCurrentNetwork(name)
        }
    }

    @objc private func overrideRoutes(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? RoutesOverrideBox else { return }
        let name = box.profile, routes = box.routes
        perform(routes == "on" ? "use \(name) routes" : "skip \(name) routes") { client in
            _ = try client.setLocationOverride(name, routes: routes)
        }
    }

    @objc private func clearRoutesOverride(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        perform("return \(name) to automatic routes") { client in
            _ = try client.clearLocationOverride(name)
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

    // MARK: Notifications

    /// nil when not running from an app bundle (for example `swift run`),
    /// where the notification center is unavailable.
    private var notificationCenter: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    private var sentNotifications: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.sentNotificationsKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: Self.sentNotificationsKey) }
    }

    /// Posts each sign-in notification once per episode. Called only with a
    /// snapshot from the daemon, so an unreachable daemon leaves the
    /// remembered episodes alone.
    private func notifySignIn(_ profiles: [Profile]) {
        guard let center = notificationCenter else { return }
        let sent = sentNotifications
        let plan = SignInNotifications.plan(profiles: profiles, sent: sent, now: Date())
        if plan.sent != sent { sentNotifications = plan.sent }
        guard !plan.post.isEmpty else { return }
        let requests = plan.post.map { notification in
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.sound = .default
            content.userInfo = ["profileID": notification.profileID]
            return UNNotificationRequest(identifier: notification.key, content: content, trigger: nil)
        }
        // Asks for permission the first time; once decided, macOS remembers.
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("tailmix Menu: notifications not authorized: %@", error.localizedDescription)
            }
            guard granted else { return }
            for request in requests {
                center.add(request) { error in
                    if let error {
                        NSLog("tailmix Menu: could not post notification: %@", error.localizedDescription)
                    }
                }
            }
        }
    }

    /// Shows notifications even while the menu is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let profileID = response.notification.request.content.userInfo["profileID"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.openSignIn(profileID: profileID) }
        }
        completionHandler()
    }

    /// Opens the profile's sign-in link, or the menu when there is none yet.
    private func openSignIn(profileID: String?) {
        refreshNow()
        if let profile = snapshot?.status.profiles.first(where: { $0.id == profileID }),
           !profile.authURL.isEmpty, let url = URL(string: profile.authURL) {
            NSWorkspace.shared.open(url)
        } else {
            statusItem.button?.performClick(nil)
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
