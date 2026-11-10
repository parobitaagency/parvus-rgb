import Carbon.HIToolbox

/// One system-wide shortcut: ⌃⌥⌘L. Carbon hot keys need no permission.
@MainActor
final class Hotkey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let hotkey = Unmanaged<Hotkey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotkey.action() }
            return noErr
        }, 1, &spec, context, &handler)
        let id = EventHotKeyID(signature: OSType(0x5052_5653), id: 1) // "PRVS"
        RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(controlKey | optionKey | cmdKey), id,
                            GetApplicationEventTarget(), 0, &reference)
    }
}
