import AppKit

// MARK: - Custom menu row

final class SpaceRowView: NSView {
    private static let rowWidth: CGFloat = 300
    private static let compactRowHeight: CGFloat = 26
    private static let thumbnailRowHeight: CGFloat = 54
    private static let thumbnailSize = NSSize(width: 72, height: 45)

    private let rowHeight: CGFloat
    private let isActive: Bool
    private let canSwitch: Bool
    private let canRename: Bool
    private let canDelete: Bool
    private let onSwitch: () -> Void
    private let onRename: () -> Void
    private let onDelete: () -> Void

    private let thumbnailView = NSImageView()
    private let iconView = NSImageView()
    private let textStack = NSStackView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let ageLabel = NSTextField(labelWithString: "")
    private let checkmark = NSImageView()
    private let actionStack = NSStackView()
    private let renameAction = SpaceRowActionButton(symbolName: "pencil",
                                                    accessibilityDescription: "Rename…",
                                                    tintColor: .controlAccentColor)
    private let deleteAction = SpaceRowActionButton(symbolName: "trash",
                                                    accessibilityDescription: "Delete Space…",
                                                    tintColor: .systemRed)

    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(name: String,
         thumbnail: SpaceThumbnail?,
         iconImage: NSImage?,
         isActive: Bool, canSwitch: Bool,
         canRename: Bool, canDelete: Bool,
         onSwitch: @escaping () -> Void,
         onRename: @escaping () -> Void,
         onDelete: @escaping () -> Void) {
        let resolvedRowHeight = thumbnail == nil
            ? Self.compactRowHeight
            : Self.thumbnailRowHeight
        self.rowHeight = resolvedRowHeight
        self.isActive = isActive
        self.canSwitch = canSwitch
        self.canRename = canRename
        self.canDelete = canDelete
        self.onSwitch = onSwitch
        self.onRename = onRename
        self.onDelete = onDelete
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: Self.rowWidth,
                                 height: resolvedRowHeight))
        wantsLayer = true
        autoresizingMask = [.width]
        renameAction.target = self
        renameAction.action = #selector(renameClicked)
        deleteAction.target = self
        deleteAction.action = #selector(deleteClicked)

        if let thumbnail {
            thumbnailView.image = thumbnail.image
            thumbnailView.toolTip = Self.ageText(for: thumbnail.capturedAt)
        }
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 4
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.backgroundColor = NSColor.separatorColor
            .withAlphaComponent(0.35).cgColor
        thumbnailView.isHidden = thumbnail == nil
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumbnailView)

        if let iconImage {
            iconView.image = iconImage
            iconView.contentTintColor = nil
        } else {
            iconView.image = NSImage(systemSymbolName: "display",
                                     accessibilityDescription: nil)
            iconView.contentTintColor = .secondaryLabelColor
        }
        iconView.imageScaling = .scaleProportionallyDown
        iconView.isHidden = thumbnail != nil
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        nameLabel.stringValue = name
        nameLabel.font = .menuFont(ofSize: 0)
        nameLabel.textColor = .labelColor
        nameLabel.usesSingleLineMode = true
        nameLabel.maximumNumberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        if let thumbnail {
            ageLabel.stringValue = Self.ageText(for: thumbnail.capturedAt)
        }
        ageLabel.font = .systemFont(ofSize: 11)
        ageLabel.textColor = .secondaryLabelColor
        ageLabel.usesSingleLineMode = true
        ageLabel.maximumNumberOfLines = 1
        ageLabel.lineBreakMode = .byTruncatingTail
        ageLabel.isHidden = thumbnail == nil
        ageLabel.translatesAutoresizingMaskIntoConstraints = false

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(nameLabel)
        textStack.addArrangedSubview(ageLabel)
        addSubview(textStack)

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
        actionStack.addArrangedSubview(renameAction)
        actionStack.addArrangedSubview(deleteAction)
        addSubview(actionStack)

        var constraints = [
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: actionStack.leadingAnchor, constant: -8),

            actionStack.trailingAnchor.constraint(equalTo: checkmark.leadingAnchor, constant: -8),
            actionStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            checkmark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            checkmark.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkmark.widthAnchor.constraint(equalToConstant: 14),
            checkmark.heightAnchor.constraint(equalToConstant: 14),
        ]

        if thumbnail == nil {
            constraints.append(contentsOf: [
                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 16),
                iconView.heightAnchor.constraint(equalToConstant: 16),
                textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            ])
        } else {
            constraints.append(contentsOf: [
                thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                thumbnailView.centerYAnchor.constraint(equalTo: centerYAnchor),
                thumbnailView.widthAnchor.constraint(equalToConstant: Self.thumbnailSize.width),
                thumbnailView.heightAnchor.constraint(equalToConstant: Self.thumbnailSize.height),
                textStack.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: 10),
            ])
        }
        NSLayoutConstraint.activate(constraints)

        updateActionIconVisibility()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.rowWidth, height: rowHeight)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if !actionStack.isHidden {
            let pointInActions = actionStack.convert(point, from: self)
            if let hit = actionStack.hitTest(pointInActions) {
                return hit
            }
        }
        return self
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
        guard canRename || canDelete else { return false }

        let ctx = NSMenu()
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
        let hasVisibleAction = isHovered && (canRename || canDelete)
        actionStack.isHidden = !hasVisibleAction
        renameAction.isHidden = !hasVisibleAction || !canRename
        deleteAction.isHidden = !hasVisibleAction || !canDelete
    }

    private static func ageText(for capturedAt: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(capturedAt)))
        if seconds < 60 { return "Captured just now" }

        let minutes = seconds / 60
        if minutes < 60 {
            return "Captured \(minutes)m ago"
        }

        let hours = minutes / 60
        if hours < 24 {
            return "Captured \(hours)h ago"
        }

        let days = hours / 24
        return "Captured \(days)d ago"
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1),
                                xRadius: 4, yRadius: 4)
        NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
        path.fill()
    }
}

private final class SpaceRowActionButton: NSButton {
    private let tintColor: NSColor

    init(symbolName: String,
         accessibilityDescription: String,
         tintColor: NSColor) {
        self.tintColor = tintColor
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        wantsLayer = true
        toolTip = accessibilityDescription
        translatesAutoresizingMaskIntoConstraints = false
        image = NSImage(systemSymbolName: symbolName,
                        accessibilityDescription: accessibilityDescription)
        image?.size = NSSize(width: 13, height: 13)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        contentTintColor = tintColor

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
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
        super.draw(dirtyRect)
    }
}
