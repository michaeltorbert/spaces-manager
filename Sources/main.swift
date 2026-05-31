import AppKit
import Carbon.HIToolbox
import Foundation
import Sparkle

// MARK: - Private CoreGraphics Services bindings (read-only; no injection)

typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSGetActiveSpace")
func CGSGetActiveSpace(_ cid: CGSConnectionID) -> CGSSpaceID

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray

@_silgen_name("CGSSpaceDestroy")
func CGSSpaceDestroy(_ cid: CGSConnectionID, _ space: CGSSpaceID)

@_silgen_name("SLSCopyWindowsWithOptionsAndTags")
func SLSCopyWindowsWithOptionsAndTags(_ cid: CGSConnectionID,
                                       _ owner: UInt32,
                                       _ spaces: CFArray,
                                       _ options: UInt32,
                                       _ setTags: UnsafeMutablePointer<UInt64>,
                                       _ clearTags: UnsafeMutablePointer<UInt64>) -> CFArray?

// Returns the owner's WindowServer connection ID (not a PID), via the out param.
@_silgen_name("SLSGetWindowOwner")
func SLSGetWindowOwner(_ cid: CGSConnectionID,
                        _ windowID: UInt32,
                        _ ownerConnection: UnsafeMutablePointer<Int32>) -> Int32

// Resolves a WindowServer connection ID to the owning process's PID.
@_silgen_name("SLSConnectionGetPID")
func SLSConnectionGetPID(_ ownerConnection: Int32,
                          _ pid: UnsafeMutablePointer<pid_t>) -> Int32

@_silgen_name("SLSGetWindowLevel")
func SLSGetWindowLevel(_ cid: CGSConnectionID,
                        _ windowID: UInt32,
                        _ level: UnsafeMutablePointer<Int32>) -> Int32

// MARK: - Space model

struct Space {
    let key: String          // uuid if non-empty, else "<displayID>:desktop:<regularIndex>"
    let uuid: String         // raw, may be empty
    let id64: CGSSpaceID     // CGS internal
    let managedID: Int       // ManagedSpaceID from plist; -1 if missing
    let displayID: String
    let regularIndex: Int    // 1-based within display, 0 for fullscreen tiles
    let isFullscreen: Bool

    var defaultName: String {
        isFullscreen ? "Full Screen" : "Desktop \(regularIndex)"
    }
}

struct Snapshot {
    let spaces: [Space]
    let activeKey: String?
}

// MARK: - Snapshot provider

enum SpacesProvider {
    static func snapshot() -> Snapshot {
        let cid = CGSMainConnectionID()
        let displays = (CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]]) ?? plistFallback()
        let activeID = CGSGetActiveSpace(cid)

        var spaces: [Space] = []
        var activeByID64: String?
        var activeByPlistCurrent: String?

        for display in displays {
            let displayID = (display["Display Identifier"] as? String) ?? ""
            guard let list = display["Spaces"] as? [[String: Any]] else { continue }

            let currentInfo = display["Current Space"] as? [String: Any]
            let currentManaged = (currentInfo?["ManagedSpaceID"] as? NSNumber)?.intValue
            let currentUUID = currentInfo?["uuid"] as? String

            var regular = 0
            for sp in list {
                let fullscreen = (sp["TileLayoutManager"] != nil)
                    || ((sp["type"] as? NSNumber)?.intValue == 4)
                if !fullscreen { regular += 1 }

                let uuid = (sp["uuid"] as? String) ?? ""
                let id64 = (sp["id64"] as? NSNumber)?.uint64Value ?? 0
                let managed = (sp["ManagedSpaceID"] as? NSNumber)?.intValue ?? -1
                let key = !uuid.isEmpty
                    ? uuid
                    : "\(displayID):desktop:\(regular)"

                let space = Space(
                    key: key, uuid: uuid, id64: id64, managedID: managed,
                    displayID: displayID,
                    regularIndex: fullscreen ? 0 : regular,
                    isFullscreen: fullscreen
                )
                spaces.append(space)

                if activeByID64 == nil, id64 != 0, id64 == activeID {
                    activeByID64 = key
                }
                let plistHit = (currentManaged.map { $0 == managed } ?? false)
                    || (currentUUID.map { !$0.isEmpty && $0 == uuid } ?? false)
                if activeByPlistCurrent == nil, plistHit {
                    activeByPlistCurrent = key
                }
            }
        }
        return Snapshot(spaces: spaces, activeKey: activeByID64 ?? activeByPlistCurrent)
    }

    private static func plistFallback() -> [[String: Any]] {
        let path = ("~/Library/Preferences/com.apple.spaces.plist" as NSString)
            .expandingTildeInPath
        guard let root = NSDictionary(contentsOfFile: path),
              let monitors = root.value(forKeyPath:
                "SpacesDisplayConfiguration.Management Data.Monitors") as? [[String: Any]]
        else { return [] }
        return monitors
    }
}

// MARK: - Per-space window inspection

/// Shared filter for "normal user app windows" on a space. Both the window
/// count (#22) and the dominant-app detection (#23) need to apply the same
/// criteria so the subtitle/icon match the parenthesized count and Dock /
/// SystemUIServer / utility-panel / accessory-agent windows can't dominate
/// either calculation.
///
/// A window is included if all of the following hold:
///   - `SLSCopyWindowsWithOptionsAndTags(..., options: 2)` returns it
///     (on-screen, not minimized/hidden),
///   - `SLSGetWindowLevel == 0` (kCGNormalWindowLevel — excludes status bar,
///     Dock, menus, tooltips, floating/utility panels, sticky overlays),
///   - the owner connection resolves to a PID > 1 that isn't our own,
///   - `NSRunningApplication(processIdentifier:)` returns an app with
///     `activationPolicy == .regular` (excludes daemons, agents, and
///     accessory apps).
enum SpaceWindowInspector {
    static func forEachUserAppWindow(forSpace id64: CGSSpaceID,
                                     _ body: (NSRunningApplication) -> Void) {
        guard id64 != 0 else { return }
        let cid = CGSMainConnectionID()
        let spaces = [NSNumber(value: id64)] as CFArray
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        guard let windows = SLSCopyWindowsWithOptionsAndTags(
            cid, 0, spaces, 2, &setTags, &clearTags) as? [Int]
        else { return }

        let ourPid = getpid()
        var appCache: [pid_t: NSRunningApplication?] = [:]
        for wid in windows {
            var level: Int32 = 0
            guard SLSGetWindowLevel(cid, UInt32(wid), &level) == 0,
                  level == 0
            else { continue }

            var ownerCID: Int32 = 0
            guard SLSGetWindowOwner(cid, UInt32(wid), &ownerCID) == 0
            else { continue }
            var pid: pid_t = 0
            guard SLSConnectionGetPID(ownerCID, &pid) == 0,
                  pid > 1, pid != ourPid
            else { continue }

            let app: NSRunningApplication?
            if let cached = appCache[pid] {
                app = cached
            } else {
                app = NSRunningApplication(processIdentifier: pid)
                appCache[pid] = app
            }
            guard let app, app.activationPolicy == .regular else { continue }

            body(app)
        }
    }
}

// MARK: - Window counts per space

enum WindowCounter {
    /// Count of on-screen, normal-level windows on the given space owned by a
    /// regular (Dock-visible) app. See `SpaceWindowInspector` for the exact
    /// filter. Returns 0 if the space ID is unknown or the private API calls
    /// fail.
    static func count(forSpace id64: CGSSpaceID) -> Int {
        var count = 0
        SpaceWindowInspector.forEachUserAppWindow(forSpace: id64) { _ in
            count += 1
        }
        return count
    }
}

// MARK: - Dominant-app detection

enum DominantAppFinder {
    /// Returns the regular (Dock-visible) app that owns the most normal-level
    /// user windows on the given space, or nil if no such windows exist. Uses
    /// the same filter as `WindowCounter` so the subtitle/icon line up with
    /// the `(N)` count and so utility / accessory owners can't dominate.
    static func find(forSpace id64: CGSSpaceID) -> NSRunningApplication? {
        var pidCounts: [pid_t: Int] = [:]
        var appsByPid: [pid_t: NSRunningApplication] = [:]
        SpaceWindowInspector.forEachUserAppWindow(forSpace: id64) { app in
            pidCounts[app.processIdentifier, default: 0] += 1
            appsByPid[app.processIdentifier] = app
        }
        guard let topPid = pidCounts.max(by: { $0.value < $1.value })?.key
        else { return nil }
        return appsByPid[topPid]
    }
}

// MARK: - Mission Control launcher (public API only)

/// Tahoe broke the private `(CGS|SLS)ManagedDisplaySetCurrentSpace` switch
/// path — calling it doesn't actually move the active space, it just
/// activates whatever app is on the target space, which surfaces those
/// app windows on top of the current space's content (the symptom the
/// user reports). Until a working zero-permission switch path is found
/// (without Accessibility, which we want to avoid), the best UX is to
/// open Mission Control and let the user click the space they want.
enum MissionControl {
    static func open() {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config,
                                           completionHandler: nil)
    }
}

// MARK: - Name store

final class NameStore {
    private let defaults = UserDefaults.standard
    private let key = "spaceNames"

    init() {
        // One-shot migration from prior bundle id `local.spaceshud`.
        if defaults.dictionary(forKey: key) == nil,
           let legacy = UserDefaults(suiteName: "local.spaceshud")?
                            .dictionary(forKey: key) {
            defaults.set(legacy, forKey: key)
        }
    }

    func name(for spaceKey: String) -> String? {
        let dict = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return dict[spaceKey]
    }

    func setName(_ name: String?, for spaceKey: String) {
        var dict = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        if let name, !name.isEmpty {
            dict[spaceKey] = name
        } else {
            dict.removeValue(forKey: spaceKey)
        }
        defaults.set(dict, forKey: key)
    }

    func displayName(for space: Space) -> String {
        if let n = name(for: space.key), !n.isEmpty { return n }
        return space.defaultName
    }
}

// MARK: - Custom menu row (click body to switch; hover shows Rename pill)

final class SpaceRowView: NSView {
    private let isActive: Bool
    private let canSwitch: Bool
    private let onSwitch: () -> Void
    private let onRename: () -> Void
    private let onDelete: () -> Void

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let checkmark = NSImageView()

    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(name: String, subtitle: String?, iconImage: NSImage?,
         isActive: Bool, canSwitch: Bool,
         onSwitch: @escaping () -> Void,
         onRename: @escaping () -> Void,
         onDelete: @escaping () -> Void) {
        self.isActive = isActive
        self.canSwitch = canSwitch
        self.onSwitch = onSwitch
        self.onRename = onRename
        self.onDelete = onDelete
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        wantsLayer = true
        autoresizingMask = [.width]

        if let iconImage {
            iconView.image = iconImage
            iconView.contentTintColor = nil
        } else {
            iconView.image = NSImage(systemSymbolName: "display",
                                     accessibilityDescription: nil)
            iconView.contentTintColor = .secondaryLabelColor
        }
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        let menuFont = NSFont.menuFont(ofSize: 0)
        let attr = NSMutableAttributedString(string: name, attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: menuFont,
        ])
        if let subtitle, !subtitle.isEmpty {
            attr.append(NSAttributedString(string: " · \(subtitle)", attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: menuFont,
            ]))
        }
        nameLabel.attributedStringValue = attr
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        checkmark.image = NSImage(systemSymbolName: "checkmark",
                                  accessibilityDescription: nil)
        checkmark.contentTintColor = .controlAccentColor
        checkmark.isHidden = !isActive
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkmark)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: checkmark.leadingAnchor, constant: -8),

            checkmark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            checkmark.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkmark.widthAnchor.constraint(equalToConstant: 14),
            checkmark.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

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
        enclosingMenuItem?.menu?.cancelTracking()
        if canSwitch && !isActive { onSwitch() }
    }

    /// Build and show the Rename / Delete context menu anchored at the given
    /// screen-space point. Called by both the NSView rightMouseDown override
    /// (when AppKit delivers it) and by the menu-scoped NSEvent monitor in
    /// AppDelegate (when AppKit doesn't, as on macOS Tahoe — see #11).
    func showContextMenu(atScreenPoint screenPoint: NSPoint? = nil,
                         from event: NSEvent? = nil) {
        let ctx = NSMenu()
        let rename = NSMenuItem(title: "Rename…",
                                action: #selector(renameClicked),
                                keyEquivalent: "")
        rename.target = self
        ctx.addItem(rename)

        let delete = NSMenuItem(title: "Delete Space…",
                                action: #selector(deleteClicked),
                                keyEquivalent: "")
        delete.target = self
        ctx.addItem(delete)

        if let event {
            NSMenu.popUpContextMenu(ctx, with: event, for: self)
        } else {
            // Position under the bottom-left of the row when there's no event
            // (e.g. invoked from a keyboard shortcut later). Falls back to the
            // current cursor position by way of NSMenu's default behavior.
            let origin = screenPoint.flatMap { window?.convertPoint(fromScreen: $0) }
                ?? NSPoint(x: 0, y: bounds.height)
            ctx.popUp(positioning: nil, at: origin, in: self)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // On macOS where this delivery works, use it directly. On Tahoe the
        // AppDelegate-side NSEvent local monitor handles right-clicks
        // because this override doesn't get called inside a custom
        // NSMenuItem.view. Both paths route to the same context menu.
        showContextMenu(from: event)
    }

    @objc private func renameClicked() {
        enclosingMenuItem?.menu?.cancelTracking()
        onRename()
    }

    @objc private func deleteClicked() {
        enclosingMenuItem?.menu?.cancelTracking()
        onDelete()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1),
                                xRadius: 4, yRadius: 4)
        NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
        path.fill()
    }
}

// MARK: - Global hotkeys (Carbon, no Accessibility permission required)

/// Binds ⌃⌥⌘1..⌃⌥⌘9 to call `action(0..8)` from anywhere in the system.
/// Uses Carbon's RegisterEventHotKey — deprecated but still functional and the
/// only zero-permission path for system-wide hotkeys.
///
/// Registration is **opt-in**: `init` installs the event handler but does not
/// reserve any hotkeys. Call `register()` to claim the shortcuts and
/// `unregister()` to release them. The gating exists because the underlying
/// `switchTo(space:)` path is reported as not actually switching spaces on
/// macOS Tahoe (see #10) — claiming the shortcuts before that is fixed would
/// silently consume them system-wide without delivering the action.
final class GlobalHotkeys {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private let action: (Int) -> Void
    private var isRegistered = false

    init(action: @escaping (Int) -> Void) {
        self.action = action
        installHandler()
    }

    deinit {
        unregister()
        if let handler { RemoveEventHandler(handler) }
    }

    /// Reserve ⌃⌥⌘1..⌃⌥⌘9 system-wide. No-op if already registered.
    func register() {
        guard !isRegistered else { return }
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let codes: [UInt32] = [
            UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
            UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
            UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9),
        ]
        let signature = fourCharCode("SPMN")
        for (i, code) in codes.enumerated() {
            let id = EventHotKeyID(signature: signature, id: UInt32(i + 1))
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(code, modifiers, id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) }
        }
        isRegistered = true
    }

    /// Release any reserved hotkeys. Safe to call when not registered.
    func unregister() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs = []
        isRegistered = false
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hkid = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkid)
                guard status == noErr else { return status }
                let owner = Unmanaged<GlobalHotkeys>.fromOpaque(userData).takeUnretainedValue()
                owner.action(Int(hkid.id) - 1)
                return noErr
            },
            1, &spec, userData, &handler)
    }

    private func fourCharCode(_ s: String) -> OSType {
        var v: OSType = 0
        for byte in s.utf8 { v = (v << 8) | OSType(byte) }
        return v
    }
}

// MARK: - HUD

final class HUDWindow: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private var hideTimer: Timer?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary,
                              .ignoresCycle, .fullScreenAuxiliary]

        let bg = NSVisualEffectView(frame: contentView!.bounds)
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 20
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]
        contentView = bg

        label.font = .systemFont(ofSize: 36, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: bg.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: bg.trailingAnchor, constant: -24),
        ])
    }

    func show(text: String) {
        label.stringValue = text
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let w: CGFloat = 360, h: CGFloat = 120
            setFrame(NSRect(x: f.midX - w / 2, y: f.maxY - h - 80, width: w, height: h),
                     display: true)
        }
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            animator().alphaValue = 1.0
        }
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in
            self?.fadeOut()
        }
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let store = NameStore()
    private let hud = HUDWindow()
    private var lastActiveKey: String?
    private var editorWindow: NSWindow?
    private var editorFields: [(key: String, field: NSTextField)] = []
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
        // Registration is gated until the underlying space-switch path is
        // confirmed working on macOS Tahoe (see #10). Until then, reserving
        // ⌃⌥⌘1..9 system-wide would silently consume those shortcuts without
        // delivering the user-visible action. Power users can opt in via:
        //   defaults write local.spacesmanager enableGlobalHotkeys -bool YES
        if UserDefaults.standard.bool(forKey: "enableGlobalHotkeys") {
            hotkeys?.register()
        }
    }

    private func switchToSpace(atIndex index: Int) {
        let snap = SpacesProvider.snapshot()
        let grouped = Dictionary(
            grouping: snap.spaces.filter { !$0.isFullscreen },
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
            for sp in (grouped[display] ?? []) where !sp.isFullscreen {
                let baseName = store.displayName(for: sp)
                let count = WindowCounter.count(forSpace: sp.id64)
                let displayed = count > 0 ? "\(baseName) (\(count))" : baseName
                let isActive = (sp.key == snap.activeKey)
                let dominantApp = dominantApp(for: sp, isActive: isActive)
                let canSwitch = !sp.displayID.isEmpty && sp.id64 != 0
                let item = NSMenuItem()
                item.view = SpaceRowView(
                    name: displayed,
                    subtitle: dominantApp?.localizedName,
                    iconImage: dominantApp?.icon,
                    isActive: isActive,
                    canSwitch: canSwitch,
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
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdates.target = updaterController
        menu.addItem(checkForUpdates)

        let quit = NSMenuItem(title: "Quit SpacesManager",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
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
        // The private direct-switch APIs (CGS/SLSManagedDisplaySetCurrentSpace)
        // no longer move the active space on macOS Tahoe — calling them just
        // activates whatever app is on the target space, which surfaces those
        // windows on top of the current space's content. Routing through
        // Mission Control is the only reliable zero-permission switch on
        // current macOS: one click opens Mission Control, a second click on
        // the target thumbnail does the actual move. See #10.
        _ = space  // accepted but unused while we don't have a direct path
        MissionControl.open()
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

// MARK: - Entry

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
