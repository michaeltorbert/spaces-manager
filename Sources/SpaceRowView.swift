import AppKit

// MARK: - Custom menu row

final class SpaceRowView: NSView {
    private let isActive: Bool
    private let canSwitch: Bool
    private let canRename: Bool
    private let canDelete: Bool
    private let canMoveWindow: Bool
    private let onSwitch: () -> Void
    private let onMoveWindow: () -> Void
    private let onRename: () -> Void
    private let onDelete: () -> Void

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let checkmark = NSImageView()
    private let actionStack = NSStackView()
    private let moveWindowAction = SpaceRowActionView(symbolName: "arrow.right.square",
                                                      accessibilityDescription: "Move Frontmost Window Here",
                                                      tintColor: .controlAccentColor)
    private let renameAction = SpaceRowActionView(symbolName: "pencil",
                                                  accessibilityDescription: "Rename…",
                                                  tintColor: .controlAccentColor)
    private let deleteAction = SpaceRowActionView(symbolName: "trash",
                                                  accessibilityDescription: "Delete Space…",
                                                  tintColor: .systemRed)

    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(name: String, iconImage: NSImage?,
         isActive: Bool, canSwitch: Bool,
         canRename: Bool, canDelete: Bool,
         canMoveWindow: Bool,
         onSwitch: @escaping () -> Void,
         onMoveWindow: @escaping () -> Void,
         onRename: @escaping () -> Void,
         onDelete: @escaping () -> Void) {
        self.isActive = isActive
        self.canSwitch = canSwitch
        self.canRename = canRename
        self.canDelete = canDelete
        self.canMoveWindow = canMoveWindow
        self.onSwitch = onSwitch
        self.onMoveWindow = onMoveWindow
        self.onRename = onRename
        self.onDelete = onDelete
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
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

        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = 6
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.addArrangedSubview(moveWindowAction)
        actionStack.addArrangedSubview(renameAction)
        actionStack.addArrangedSubview(deleteAction)
        addSubview(actionStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionStack.leadingAnchor, constant: -8),

            actionStack.trailingAnchor.constraint(equalTo: checkmark.leadingAnchor, constant: -8),
            actionStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            checkmark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            checkmark.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkmark.widthAnchor.constraint(equalToConstant: 14),
            checkmark.heightAnchor.constraint(equalToConstant: 14),
        ])

        updateActionIconVisibility()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 300, height: 26)
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
        updateActionIconVisibility()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateActionIconVisibility()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if !moveWindowAction.isHidden && contains(point, in: moveWindowAction) {
            let action = onMoveWindow
            enclosingMenuItem?.menu?.cancelTracking()
            DispatchQueue.main.async { action() }
            return
        }

        if !deleteAction.isHidden && contains(point, in: deleteAction) {
            let action = onDelete
            enclosingMenuItem?.menu?.cancelTracking()
            DispatchQueue.main.async { action() }
            return
        }

        if !renameAction.isHidden && contains(point, in: renameAction) {
            let action = onRename
            enclosingMenuItem?.menu?.cancelTracking()
            DispatchQueue.main.async { action() }
            return
        }

        enclosingMenuItem?.menu?.cancelTracking()
        if canSwitch && !isActive { onSwitch() }
    }

    @discardableResult
    func showContextMenu(from event: NSEvent) -> Bool {
        guard canMoveWindow || canRename || canDelete else { return false }

        let ctx = NSMenu()
        if canMoveWindow {
            let moveWindow = NSMenuItem(title: "Move Frontmost Window Here",
                                        action: #selector(moveWindowClicked),
                                        keyEquivalent: "")
            moveWindow.target = self
            ctx.addItem(moveWindow)
            ctx.addItem(NSMenuItem.separator())
        }

        if canRename {
            let rename = NSMenuItem(title: "Rename…",
                                    action: #selector(renameClicked),
                                    keyEquivalent: "")
            rename.target = self
            ctx.addItem(rename)
        }

        if canDelete {
            let delete = NSMenuItem(title: "Delete Space…",
                                    action: #selector(deleteClicked),
                                    keyEquivalent: "")
            delete.target = self
            ctx.addItem(delete)
        }

        NSMenu.popUpContextMenu(ctx, with: event, for: self)
        return true
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(from: event)
    }

    @objc private func moveWindowClicked() {
        enclosingMenuItem?.menu?.cancelTracking()
        onMoveWindow()
    }

    @objc private func renameClicked() {
        let action = onRename
        enclosingMenuItem?.menu?.cancelTracking()
        DispatchQueue.main.async { action() }
    }

    @objc private func deleteClicked() {
        enclosingMenuItem?.menu?.cancelTracking()
        onDelete()
    }

    private func contains(_ point: NSPoint, in actionView: NSView) -> Bool {
        let pointInAction = actionView.convert(point, from: self)
        return actionView.bounds.insetBy(dx: -4, dy: -3).contains(pointInAction)
    }

    private func updateActionIconVisibility() {
        let hasVisibleAction = isHovered && (canMoveWindow || canRename || canDelete)
        actionStack.isHidden = !hasVisibleAction
        moveWindowAction.isHidden = !hasVisibleAction || !canMoveWindow
        renameAction.isHidden = !hasVisibleAction || !canRename
        deleteAction.isHidden = !hasVisibleAction || !canDelete
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1),
                                xRadius: 4, yRadius: 4)
        NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
        path.fill()
    }
}

private final class SpaceRowActionView: NSView {
    private let imageView = NSImageView()
    private let tintColor: NSColor

    init(symbolName: String,
         accessibilityDescription: String,
         tintColor: NSColor) {
        self.tintColor = tintColor
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        wantsLayer = true
        toolTip = accessibilityDescription
        translatesAutoresizingMaskIntoConstraints = false

        imageView.image = NSImage(systemSymbolName: symbolName,
                                  accessibilityDescription: accessibilityDescription)
        imageView.contentTintColor = tintColor
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 13),
            imageView.heightAnchor.constraint(equalToConstant: 13),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                xRadius: 5,
                                yRadius: 5)
        tintColor.withAlphaComponent(0.17).setFill()
        path.fill()
        tintColor.withAlphaComponent(0.36).setStroke()
        path.lineWidth = 0.6
        path.stroke()
    }
}
