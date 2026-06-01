import Carbon.HIToolbox

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
