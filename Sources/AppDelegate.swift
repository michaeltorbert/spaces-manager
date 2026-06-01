import AppKit
import Sparkle

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let store = NameStore()
    private let hud = HUDWindow()
    private var lastActiveKey: String?
    private var editorWindow: NSWindow?
    private var editorFields: [(key: String, field: NSTextField)] = []
    private var hasShownSwitchPermissionAlert = false
    private var releaseCheckInFlight = false
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var hotkeys: GlobalHotkeys?
    private var menuRightClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.grid.2x2",
                                   accessibilityDescription: "Spaces")
            button.imagePosition = .imageLeft
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refresh()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(refresh),
            name: NSNotification.Name("com.apple.exposeworkspacesdidchange"),
            object: nil)

        hotkeys = GlobalHotkeys { [weak self] index in
            self?.switchToSpace(atIndex: index)
        }
        // Registration is opt-in because the switch path requires the app to
        // have Accessibility permission. Power users can opt in via:
        //   defaults write local.spacesmanager enableGlobalHotkeys -bool YES
        if UserDefaults.standard.bool(forKey: "enableGlobalHotkeys") {
            hotkeys?.register()
        }
    }

    private func switchToSpace(atIndex index: Int) {
        let snap = SpacesProvider.snapshot()
        let grouped = Dictionary(
            grouping: snap.spaces,
            by: { $0.displayID })
        let ordered = grouped.keys.sorted().flatMap { grouped[$0] ?? [] }
        guard index >= 0, index < ordered.count else { return }
        switchTo(space: ordered[index])
    }

    @objc func refresh() {
        let snap = SpacesProvider.snapshot()
        lastActiveKey = snap.activeKey
        updateStatusTitle(snap: snap)
    }

    @objc func activeSpaceChanged() {
        let snap = SpacesProvider.snapshot()
        defer {
            lastActiveKey = snap.activeKey
            updateStatusTitle(snap: snap)
        }
        guard let activeKey = snap.activeKey, activeKey != lastActiveKey,
              let sp = snap.spaces.first(where: { $0.key == activeKey })
        else { return }
        hud.show(text: store.displayName(for: sp))
    }

    private func updateStatusTitle(snap: Snapshot? = nil) {
        let s = snap ?? SpacesProvider.snapshot()
        if let key = s.activeKey, let sp = s.spaces.first(where: { $0.key == key }) {
            statusItem.button?.title = " \(store.displayName(for: sp))"
        } else {
            statusItem.button?.title = ""
        }
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // AppKit doesn't reliably deliver rightMouseDown to a custom
        // NSMenuItem.view on macOS Tahoe, so the row's override never fires.
        // A scoped NSEvent local monitor installed while the menu is open
        // catches the click, hit-tests it against each SpaceRowView, and
        // routes to the same context menu the row would show itself. See #11.
        if menuRightClickMonitor == nil {
            menuRightClickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.rightMouseDown]
            ) { [weak self, weak menu] event in
                guard let self, let menu else { return event }
                if self.routeRightClickToRow(event: event, menu: menu) {
                    return nil
                }
                return event
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if let monitor = menuRightClickMonitor {
            NSEvent.removeMonitor(monitor)
            menuRightClickMonitor = nil
        }
    }

    private func routeRightClickToRow(event: NSEvent, menu: NSMenu) -> Bool {
        for item in menu.items {
            guard let row = item.view as? SpaceRowView,
                  let win = row.window,
                  win == event.window
            else { continue }
            let pointInRow = row.convert(event.locationInWindow, from: nil)
            if row.bounds.contains(pointInRow) {
                row.showContextMenu(from: event)
                return true
            }
        }
        return false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let snap = SpacesProvider.snapshot()
        lastActiveKey = snap.activeKey
        let grouped = Dictionary(grouping: snap.spaces, by: { $0.displayID })
        let displayKeys = grouped.keys.sorted()

        for (di, display) in displayKeys.enumerated() {
            if displayKeys.count > 1 {
                let header = NSMenuItem()
                header.title = "Display \(di + 1)"
                header.isEnabled = false
                menu.addItem(header)
            }
            for sp in grouped[display] ?? [] {
                let currentKey = snap.currentKeysByDisplay[display] ?? snap.activeKey
                let isActive = (sp.key == currentKey)
                let dominantApp = dominantApp(for: sp, isActive: isActive)
                let baseName: String
                if sp.isFullscreen {
                    if let appName = dominantApp?.localizedName, !appName.isEmpty {
                        baseName = "\(appName) Full Screen"
                    } else {
                        baseName = sp.defaultName
                    }
                } else {
                    baseName = store.displayName(for: sp)
                }
                let count = sp.isFullscreen ? 0 : WindowCounter.count(forSpace: sp.id64)
                let displayed = count > 0 ? "\(baseName) (\(count))" : baseName
                let canSwitch = !sp.displayID.isEmpty && sp.id64 != 0
                let canManage = !sp.isFullscreen && sp.id64 != 0
                let item = NSMenuItem()
                item.view = SpaceRowView(
                    name: displayed,
                    iconImage: dominantApp?.icon,
                    isActive: isActive,
                    canSwitch: canSwitch,
                    canManage: canManage,
                    onSwitch: { [weak self] in self?.switchTo(space: sp) },
                    onRename: { [weak self] in self?.promptRename(key: sp.key) },
                    onDelete: { [weak self] in self?.confirmDelete(space: sp, name: baseName) }
                )
                menu.addItem(item)
            }
        }
        menu.addItem(NSMenuItem.separator())

        let renameCurrent = NSMenuItem(title: "Rename Current Space…",
                                       action: #selector(renameCurrentSpace),
                                       keyEquivalent: "")
        renameCurrent.target = self
        menu.addItem(renameCurrent)

        let renameAll = NSMenuItem(title: "Rename All Spaces…",
                                   action: #selector(renameAllSpaces),
                                   keyEquivalent: "")
        renameAll.target = self
        menu.addItem(renameAll)

        menu.addItem(NSMenuItem.separator())

        let checkForUpdates = NSMenuItem(
            title: isLocalDevelopmentBuild
                ? "Check for Released Version…"
                : "Check for Updates…",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdates.target = self
        menu.addItem(checkForUpdates)

        let relaunch = NSMenuItem(title: "Relaunch SpacesManager",
                                  action: #selector(relaunchSpacesManager),
                                  keyEquivalent: "")
        relaunch.target = self
        menu.addItem(relaunch)

        let quit = NSMenuItem(title: "Quit SpacesManager",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        guard isLocalDevelopmentBuild else {
            updaterController.checkForUpdates(sender)
            return
        }
        checkReleasedVersionForDevelopmentBuild(sender: sender)
    }

    private var isLocalDevelopmentBuild: Bool {
        guard let info = Bundle.main.infoDictionary else { return false }
        if let value = info["SMDevelopmentBuild"] as? Bool {
            return value
        }
        if let value = info["SMDevelopmentBuild"] as? NSNumber {
            return value.boolValue
        }
        return (info["CFBundleVersion"] as? String) == "9999999"
    }

    private var currentDisplayVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var appcastFeedURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
            return nil
        }
        return URL(string: value)
    }

    private func checkReleasedVersionForDevelopmentBuild(sender: Any?) {
        guard !releaseCheckInFlight else { return }
        guard let feedURL = appcastFeedURL else {
            updaterController.checkForUpdates(sender)
            return
        }

        releaseCheckInFlight = true
        ReleasedVersionChecker.fetchLatest(feedURL: feedURL) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.releaseCheckInFlight = false

                switch result {
                case .success(let release)
                    where ReleasedVersionChecker.compareVersions(
                        release.displayVersion,
                        self.currentDisplayVersion
                    ) == .orderedDescending:
                    self.showReleasedVersionAvailable(release)
                default:
                    self.updaterController.checkForUpdates(sender)
                }
            }
        }
    }

    private func showReleasedVersionAvailable(_ release: ReleasedVersion) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Released Version Available"
        alert.informativeText = "SpacesManager \(release.displayVersion) is available. This local development build has a high internal build number, so Sparkle cannot replace it automatically. Download the released app to switch back to the live version."
        alert.addButton(withTitle: "Download \(release.displayVersion)")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if let url = release.downloadURL ?? release.infoURL {
            NSWorkspace.shared.open(url)
        } else {
            NSSound.beep()
        }
    }

    @objc private func relaunchSpacesManager() {
        let bundlePath = Bundle.main.bundleURL.path
        let quotedPath = shellQuoted(bundlePath)
        let command = "sleep 0.4; /usr/bin/open \(quotedPath)"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", command]
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            NSSound.beep()
        }
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// "Dominant app" for a row. For the active space we prefer the currently
    /// frontmost app (when it's a regular app) — that matches what the user
    /// thinks of as "the app they're using on this space" and avoids cases
    /// where a multi-window app (e.g. Safari with many tab windows) drowns
    /// out a single-window app the user is actually working in. For inactive
    /// spaces we fall back to the most-windowed-owner heuristic.
    private func dominantApp(for space: Space, isActive: Bool) -> NSRunningApplication? {
        if isActive,
           let front = NSWorkspace.shared.frontmostApplication,
           front.activationPolicy == .regular,
           front.processIdentifier != getpid() {
            return front
        }
        return DominantAppFinder.find(forSpace: space.id64)
    }

    private func switchTo(space: Space) {
        let snap = SpacesProvider.snapshot()
        switch SpaceSwitcher.switchTo(space: space, in: snap) {
        case .switched, .alreadyActive:
            break
        case .needsAccessibility:
            requestSwitchAccessibility()
        case .unavailable:
            NSSound.beep()
        }
    }

    private func requestSwitchAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        guard !hasShownSwitchPermissionAlert else {
            SpaceSwitcher.requestAccessibilityPermission()
            return
        }

        hasShownSwitchPermissionAlert = true
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Allow SpacesManager to switch spaces"
        alert.informativeText = "Click-to-switch uses macOS Accessibility permission to send the same Dock swipe event as a trackpad space switch. SpacesManager does not need Screen Recording or SIP changes."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            SpaceSwitcher.requestAccessibilityPermission()
        }
    }

    func confirmDelete(space: Space, name: String) {
        guard space.id64 != 0 else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \(name)?"
        alert.informativeText = "This will permanently delete this space. Any windows on it will move to another space."
        let del = alert.addButton(withTitle: "Delete")
        del.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            CGSSpaceDestroy(CGSMainConnectionID(), space.id64)
            // Clear stored name for the now-deleted key so we don't pin it forever.
            store.setName(nil, for: space.key)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.refresh()
            }
        }
    }

    @objc func renameCurrentSpace() {
        let snap = SpacesProvider.snapshot()
        guard let key = snap.activeKey,
              let sp = snap.spaces.first(where: { $0.key == key }),
              !sp.isFullscreen
        else { return }
        promptRename(key: key)
    }

    private func promptRename(key: String) {
        let current = store.name(for: key) ?? ""
        let alert = NSAlert()
        alert.messageText = "Rename space"
        alert.informativeText = "Leave blank to reset to default."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = current
        alert.accessoryView = input
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            store.setName(trimmed, for: key)
            updateStatusTitle()
        }
    }

    @objc func renameAllSpaces() {
        if let existing = editorWindow {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let snap = SpacesProvider.snapshot()
        let regular = snap.spaces.filter { !$0.isFullscreen }
        guard !regular.isEmpty else { return }

        editorFields = []
        let grouped = Dictionary(grouping: regular, by: { $0.displayID })
        let displayKeys = grouped.keys.sorted()
        let multi = displayKeys.count > 1

        var rows: [NSView] = []
        for (di, display) in displayKeys.enumerated() {
            if multi {
                let header = NSTextField(labelWithString: "Display \(di + 1)")
                header.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
                rows.append(header)
            }
            for sp in grouped[display] ?? [] {
                let labelText = sp.defaultName
                let label = NSTextField(labelWithString: labelText)
                label.alignment = .right
                label.widthAnchor.constraint(equalToConstant: 100).isActive = true

                let field = NSTextField(string: store.name(for: sp.key) ?? "")
                field.placeholderString = labelText
                field.widthAnchor.constraint(equalToConstant: 260).isActive = true
                editorFields.append((sp.key, field))

                let row = NSStackView(views: [label, field])
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = 12
                rows.append(row)
            }
        }

        let fieldsStack = NSStackView(views: rows)
        fieldsStack.orientation = .vertical
        fieldsStack.alignment = .leading
        fieldsStack.spacing = 8

        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(closeEditor))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"
        let saveBtn = NSButton(title: "Save", target: self, action: #selector(saveEditor))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancelBtn, saveBtn])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let outer = NSStackView(views: [fieldsStack, buttons])
        outer.orientation = .vertical
        outer.alignment = .trailing
        outer.spacing = 16
        outer.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        outer.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: container.topAnchor),
            outer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            outer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Rename Spaces"
        window.contentView = container
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        editorWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func saveEditor() {
        for (key, field) in editorFields {
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            store.setName(trimmed, for: key)
        }
        updateStatusTitle()
        closeEditor()
    }

    @objc func closeEditor() {
        editorWindow?.close()
        editorWindow = nil
        editorFields = []
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === editorWindow {
            editorWindow = nil
            editorFields = []
        }
    }
}
