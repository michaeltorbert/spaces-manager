import AppKit

// MARK: - Custom menu row (click body to switch; hover shows Rename pill)

final class SpaceRowView: NSView {
    private let isActive: Bool
    private let canSwitch: Bool
    private let canManage: Bool
    private let onSwitch: () -> Void
    private let onRename: () -> Void
    private let onDelete: () -> Void

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let checkmark = NSImageView()

    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(name: String, iconImage: NSImage?,
         isActive: Bool, canSwitch: Bool, canManage: Bool,
         onSwitch: @escaping () -> Void,
         onRename: @escaping () -> Void,
         onDelete: @escaping () -> Void) {
        self.isActive = isActive
        self.canSwitch = canSwitch
        self.canManage = canManage
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

        nameLabel.stringValue = name
        nameLabel.font = .menuFont(ofSize: 0)
        nameLabel.textColor = .labelColor
        nameLabel.usesSingleLineMode = true
        nameLabel.maximumNumberOfLines = 1
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
    @discardableResult
    func showContextMenu(atScreenPoint screenPoint: NSPoint? = nil,
                         from event: NSEvent? = nil) -> Bool {
        guard canManage else { return false }

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
        return true
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
