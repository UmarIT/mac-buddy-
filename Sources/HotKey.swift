import Carbon.HIToolbox

/// A system-wide keyboard shortcut (Control-Option-B by default) that works even while other
/// apps are in front. Uses Carbon's hot key API, which needs no Accessibility permission.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    nonisolated(unsafe) private static var active: HotKey?

    /// Display text for the default shortcut.
    static let defaultLabel = "⌃⌥B"

    init?(keyCode: Int = kVK_ANSI_B, modifiers: Int = controlKey | optionKey, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            HotKey.active?.action()
            return noErr
        }, 1, &spec, nil, &handlerRef)
        guard installed == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x4D42_4459), id: 1)   // "MBDY"
        let registered = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id,
                                             GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
        HotKey.active = self
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
