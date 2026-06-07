import AppKit
import Sparkle

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let store = NameStore()
    private let hud = HUDWindow()
    private let thumbnailCache = ThumbnailCache()
    private var lastActiveKey: String?
    private var editorWindow: NSWindow?
    private var editorFields: [(key: String, field: NSTextField)] = []
    private var hasShownSwitchPermissionAlert = false
    private weak var maintenanceCheckItem: NSMenuItem?
    private weak var maintenanceQuitItem: NSMenuItem?
    private weak var maintenanceCheckRow: MenuCommandRowView?
    private weak var maintenanceQuitRow: MenuCommandRowView?
    private var maintenanceOptionLocalMonitor: Any?
    private var maintenanceOptionPollTimer: Timer?
    private var lastMaintenanceOptionDown: Bool?
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    private var hotkeys: GlobalHotkeys?

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
        thumbnailCache.loadFromDisk()
        updaterController.startUpdater()
        refresh()
        captureActiveThumbnail()

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
        pruneThumbnails(in: snap)
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
        pruneThumbnails(in: snap)
        thumbnailCache.capture(spaceKey: activeKey, displayID: sp.displayID)
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

    private func displayName(for displayID: String,
                             at index: Int,
                             in displayNamesByID: [String: String]) -> String {
        displayNamesByID[displayID] ?? "Display \(index + 1)"
    }

    func menuWillOpen(_ menu: NSMenu) {
        startMaintenanceOptionTracking()
    }

    func menuDidClose(_ menu: NSMenu) {
        stopMaintenanceOptionTracking()
        updateMaintenanceItems(optionDown: false, force: true)
        lastMaintenanceOptionDown = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        lastMaintenanceOptionDown = nil
        let snap = SpacesProvider.snapshot()
        pruneThumbnails(in: snap)
        lastActiveKey = snap.activeKey
        let grouped = Dictionary(grouping: snap.spaces, by: { $0.displayID })
        let displayKeys = grouped.keys.sorted()
        let showsDisplayHeaders = displayKeys.count > 1
        let displayNamesByID = showsDisplayHeaders ? DisplayNameResolver.names(for: displayKeys) : [:]
        let windowSummaries = SpaceWindowInspector.summaries(
            forSpaces: snap.spaces.map { $0.id64 }
        )

        for (di, display) in displayKeys.enumerated() {
            if showsDisplayHeaders {
                let header = NSMenuItem()
                header.title = displayName(for: display, at: di, in: displayNamesByID)
                header.isEnabled = false
                menu.addItem(header)
            }
            for sp in grouped[display] ?? [] {
                let currentKey = snap.currentKeysByDisplay[display] ?? snap.activeKey
                let isActive = (sp.key == currentKey)
                let windowSummary = windowSummaries[sp.id64]
                let dominantApp = dominantApp(
                    isActive: isActive,
                    summary: windowSummary
                )
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
                let count = sp.isFullscreen ? 0 : (windowSummary?.count ?? 0)
                let displayed = count > 0 ? "\(baseName) (\(count))" : baseName
                let canSwitch = !sp.displayID.isEmpty && sp.id64 != 0
                let canRename = canRename(space: sp)
                let canDelete = canDelete(space: sp)
                let item = NSMenuItem()
                item.view = SpaceRowView(
                    name: displayed,
                    thumbnail: thumbnailCache.thumbnail(for: sp.key),
                    iconImage: dominantApp?.icon,
                    isActive: isActive,
                    canSwitch: canSwitch,
                    canRename: canRename,
                    canDelete: canDelete,
                    onSwitch: { [weak self] in self?.switchTo(space: sp) },
                    onRename: { [weak self] in self?.promptRename(key: sp.key) },
                    onDelete: { [weak self] in self?.confirmDelete(space: sp, name: baseName) }
                )
                menu.addItem(item)
            }
        }

        if !thumbnailCache.hasScreenCaptureAccess {
            menu.addItem(NSMenuItem.separator())
            let enableThumbnails = NSMenuItem(title: "Enable Space Thumbnails…",
                                              action: #selector(requestThumbnailAccess(_:)),
                                              keyEquivalent: "")
            enableThumbnails.target = self
            enableThumbnails.view = MenuCommandRowView(
                title: "Enable Space Thumbnails…",
                shortcut: "",
                action: { [weak self] in self?.requestThumbnailAccess(nil) }
            )
            menu.addItem(enableThumbnails)
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

        let checkForUpdates = NSMenuItem(title: updateMenuTitle,
                                         action: #selector(checkForUpdates(_:)),
                                         keyEquivalent: "")
        checkForUpdates.target = self
        let checkForUpdatesRow = MenuCommandRowView(
            title: updateMenuTitle,
            shortcut: "",
            action: { [weak self] in self?.checkForUpdates(nil) }
        )
        checkForUpdates.view = checkForUpdatesRow
        menu.addItem(checkForUpdates)
        maintenanceCheckItem = checkForUpdates
        maintenanceCheckRow = checkForUpdatesRow

        let quit = NSMenuItem(title: "Quit SpacesManager",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        let quitRow = MenuCommandRowView(
            title: "Quit SpacesManager",
            shortcut: "⌘ Q",
            action: { NSApp.terminate(nil) }
        )
        quit.view = quitRow
        menu.addItem(quit)
        maintenanceQuitItem = quit
        maintenanceQuitRow = quitRow

        updateMaintenanceItems(optionDown: isOptionKeyDown, force: true)
    }

    private func captureActiveThumbnail(snap: Snapshot? = nil) {
        let s = snap ?? SpacesProvider.snapshot()
        guard let activeKey = s.activeKey,
              let sp = s.spaces.first(where: { $0.key == activeKey })
        else { return }
        thumbnailCache.capture(spaceKey: activeKey, displayID: sp.displayID)
    }

    @objc private func requestThumbnailAccess(_ sender: Any?) {
        if thumbnailCache.hasScreenCaptureAccess {
            captureActiveThumbnail()
            return
        }

        if thumbnailCache.requestScreenCaptureAccess() {
            captureActiveThumbnail()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.refresh()
            }
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Enable space thumbnails"
        alert.informativeText = "Space thumbnails need macOS Screen Recording permission. For this Terminal-launched development build, turn on Terminal in System Settings. For an installed app, turn on SpacesManager if it appears. After granting access, quit and reopen SpacesManager before testing thumbnails again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func pruneThumbnails(in snap: Snapshot) {
        thumbnailCache.prune(validKeys: Set(snap.spaces.map { $0.key }))
    }

    private func startMaintenanceOptionTracking() {
        stopMaintenanceOptionTracking()

        maintenanceOptionLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged]
        ) { [weak self] event in
            self?.updateMaintenanceItems(
                optionDown: event.modifierFlags.contains(.option),
                force: true
            )
            return event
        }

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateMaintenanceItems(
                optionDown: self?.isOptionKeyDown ?? false
            )
        }
        timer.tolerance = 0.02
        maintenanceOptionPollTimer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)

        updateMaintenanceItems(optionDown: isOptionKeyDown, force: true)
    }

    private func stopMaintenanceOptionTracking() {
        if let monitor = maintenanceOptionLocalMonitor {
            NSEvent.removeMonitor(monitor)
            maintenanceOptionLocalMonitor = nil
        }
        maintenanceOptionPollTimer?.invalidate()
        maintenanceOptionPollTimer = nil
    }

    private var isOptionKeyDown: Bool {
        NSEvent.modifierFlags.contains(.option)
            || CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
            || CGEventSource.flagsState(.hidSystemState).contains(.maskAlternate)
    }

    private func updateMaintenanceItems(optionDown: Bool, force: Bool = false) {
        guard force || lastMaintenanceOptionDown != optionDown else { return }
        lastMaintenanceOptionDown = optionDown

        if let row = maintenanceCheckRow {
            configureMaintenanceRow(
                row: row,
                item: maintenanceCheckItem,
                title: updateMenuTitle,
                shortcut: "",
                action: { [weak self] in self?.checkForUpdates(nil) },
                itemTarget: self,
                itemAction: #selector(checkForUpdates(_:)),
                keyEquivalent: ""
            )
        }

        if let row = maintenanceQuitRow {
            if optionDown {
                configureMaintenanceRow(
                    row: row,
                    item: maintenanceQuitItem,
                    title: "Relaunch SpacesManager",
                    shortcut: "",
                    action: { [weak self] in self?.relaunchSpacesManager() },
                    itemTarget: self,
                    itemAction: #selector(relaunchSpacesManager),
                    keyEquivalent: ""
                )
            } else {
                configureMaintenanceRow(
                    row: row,
                    item: maintenanceQuitItem,
                    title: "Quit SpacesManager",
                    shortcut: "⌘ Q",
                    action: { NSApp.terminate(nil) },
                    itemTarget: NSApp,
                    itemAction: #selector(NSApplication.terminate(_:)),
                    keyEquivalent: "q"
                )
            }
        }
    }

    private func configureMaintenanceRow(row: MenuCommandRowView,
                                         item: NSMenuItem?,
                                         title: String,
                                         shortcut: String,
                                         action: @escaping () -> Void,
                                         itemTarget: AnyObject?,
                                         itemAction: Selector,
                                         keyEquivalent: String) {
        row.update(title: title, shortcut: shortcut, action: action)
        item?.title = title
        item?.target = itemTarget
        item?.action = itemAction
        item?.keyEquivalent = keyEquivalent
        item?.keyEquivalentModifierMask = keyEquivalent.isEmpty ? [] : [.command]
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }

    private var isLocalDevelopmentBuild: Bool {
        guard let info = Bundle.main.infoDictionary else { return false }
        if let value = info["SMDevelopmentBuild"] as? Bool {
            return value
        }
        if let value = info["SMDevelopmentBuild"] as? NSNumber {
            return value.boolValue
        }
        let bundleVersion = info["CFBundleVersion"] as? String
        return bundleVersion == "0" || bundleVersion == "9999999"
    }

    private var updateMenuTitle: String {
        isLocalDevelopmentBuild ? "Switch to Released Version…" : "Check for Updates…"
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
    private func dominantApp(isActive: Bool,
                             summary: SpaceWindowSummary?) -> NSRunningApplication? {
        if isActive,
           let front = NSWorkspace.shared.frontmostApplication,
           front.activationPolicy == .regular,
           front.processIdentifier != getpid() {
            return front
        }
        return summary?.dominantApp
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

    private func canRename(space: Space) -> Bool {
        !space.isFullscreen && space.regularIndex > 0 && !space.key.isEmpty
    }

    private func canDelete(space: Space) -> Bool {
        canRename(space: space) && space.id64 != 0
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
        alert.informativeText = "Click-to-switch uses macOS Accessibility permission to send the same Dock swipe event as a trackpad space switch. For this Terminal-launched development build, turn on Terminal in Accessibility. For an installed app, turn on SpacesManager if it appears. This switching path does not need Screen Recording or SIP changes."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            SpaceSwitcher.requestAccessibilityPermission()
        }
    }

    func confirmDelete(space: Space, name: String) {
        guard canDelete(space: space) else { return }
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
        alert.window.initialFirstResponder = input
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(input)
            input.selectText(nil)
        }
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
        let displayNamesByID = multi ? DisplayNameResolver.names(for: displayKeys) : [:]

        var rows: [NSView] = []
        for (di, display) in displayKeys.enumerated() {
            if multi {
                let header = NSTextField(labelWithString:
                    displayName(for: display, at: di, in: displayNamesByID))
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

extension AppDelegate: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard isLocalDevelopmentBuild && updateCheck == .updatesInBackground else { return }
        throw NSError(
            domain: "local.spacesmanager",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Development builds do not check for updates in the background."
            ]
        )
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

private final class MenuCommandRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private var shortcutWidthConstraint: NSLayoutConstraint!
    private var action: () -> Void
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(title: String, shortcut: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        wantsLayer = true
        autoresizingMask = [.width]

        titleLabel.stringValue = title
        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        shortcutLabel.stringValue = shortcut
        shortcutLabel.font = .menuFont(ofSize: 0)
        shortcutLabel.textColor = .tertiaryLabelColor
        shortcutLabel.alignment = .right
        shortcutLabel.lineBreakMode = .byClipping
        shortcutLabel.maximumNumberOfLines = 1
        shortcutLabel.usesSingleLineMode = true
        shortcutLabel.isHidden = shortcut.isEmpty
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shortcutLabel)

        shortcutWidthConstraint = shortcutLabel.widthAnchor.constraint(
            equalToConstant: shortcut.isEmpty ? 0 : 48
        )

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -12),

            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutWidthConstraint,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 300, height: 30)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let opts: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        trackingArea = NSTrackingArea(rect: bounds, options: opts, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let currentAction = action
        enclosingMenuItem?.menu?.cancelTracking()
        DispatchQueue.main.async { currentAction() }
    }

    func update(title: String, shortcut: String, action: @escaping () -> Void) {
        if titleLabel.stringValue != title {
            titleLabel.stringValue = title
        }
        if shortcutLabel.stringValue != shortcut {
            shortcutLabel.stringValue = shortcut
        }
        let hasShortcut = !shortcut.isEmpty
        shortcutLabel.isHidden = !hasShortcut
        shortcutWidthConstraint.constant = hasShortcut ? 48 : 0
        self.action = action
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1),
                                xRadius: 4,
                                yRadius: 4)
        NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
        path.fill()
    }
}
