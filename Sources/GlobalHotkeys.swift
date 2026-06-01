import Carbon.HIToolbox

// MARK: - Global hotkeys (Carbon, no Accessibility permission required)

/// Binds global shortcuts from anywhere in the system. Uses Carbon's
/// RegisterEventHotKey — deprecated but still functional and the only
/// zero-permission path for system-wide hotkeys.
///
/// Registration is explicit: `init` installs the event handler but does not
/// reserve any shortcuts. Call the register methods to claim individual
/// shortcut groups and the unregister methods to release them.
final class GlobalHotkeys {
    enum Action {
        case previousSpace
        case switchToSpace(Int)
    }

    private static let previousSpaceSignature = fourCharCode("SPBK")
    private static let numberedSpacesSignature = fourCharCode("SPMN")

    private var previousSpaceRef: EventHotKeyRef?
    private var numberedRefs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private let action: (Action) -> Void
    private var areNumberedSpacesRegistered = false

    init(action: @escaping (Action) -> Void) {
        self.action = action
        installHandler()
    }

    deinit {
        unregisterPreviousSpace()
        unregisterNumberedSpaces()
        if let handler { RemoveEventHandler(handler) }
    }

    /// Reserve ⌃` system-wide to return to the previously active space.
    func registerPreviousSpace() {
        guard previousSpaceRef == nil else { return }
        let id = EventHotKeyID(signature: Self.previousSpaceSignature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_Grave),
            UInt32(controlKey),
            id,
            GetApplicationEventTarget(),
            0,
            &ref)
        if status == noErr, let ref { previousSpaceRef = ref }
    }

    /// Release the previous-space shortcut. Safe to call when not registered.
    func unregisterPreviousSpace() {
        if let previousSpaceRef {
            UnregisterEventHotKey(previousSpaceRef)
        }
        previousSpaceRef = nil
    }

    /// Reserve ⌃⌥⌘1..⌃⌥⌘9 system-wide. No-op if already registered.
    func registerNumberedSpaces() {
        guard !areNumberedSpacesRegistered else { return }
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let codes: [UInt32] = [
            UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
            UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
            UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9),
        ]
        for (i, code) in codes.enumerated() {
            let id = EventHotKeyID(signature: Self.numberedSpacesSignature, id: UInt32(i + 1))
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(code, modifiers, id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { numberedRefs.append(ref) }
        }
        areNumberedSpacesRegistered = true
    }

    /// Release the numbered space shortcuts. Safe to call when not registered.
    func unregisterNumberedSpaces() {
        for ref in numberedRefs { UnregisterEventHotKey(ref) }
        numberedRefs = []
        areNumberedSpacesRegistered = false
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
                if hkid.signature == GlobalHotkeys.previousSpaceSignature {
                    owner.action(.previousSpace)
                } else if hkid.signature == GlobalHotkeys.numberedSpacesSignature {
                    owner.action(.switchToSpace(Int(hkid.id) - 1))
                } else {
                    return OSStatus(eventNotHandledErr)
                }
                return noErr
            },
            1, &spec, userData, &handler)
    }

    private static func fourCharCode(_ s: String) -> OSType {
        var v: OSType = 0
        for byte in s.utf8 { v = (v << 8) | OSType(byte) }
        return v
    }
}
