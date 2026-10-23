import AppKit
import Carbon.HIToolbox

final class HotKey {
    nonisolated static let key = UInt32(kVK_ANSI_F)
    nonisolated static let modifiers = UInt32(controlKey | optionKey | cmdKey)

    private let action: () -> Void
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(action: @escaping () -> Void) {
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data else { return OSStatus(eventNotHandledErr) }

            MainActor.assumeIsolated { Unmanaged<HotKey>.fromOpaque(data).takeUnretainedValue().action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)

        RegisterEventHotKey(Self.key, Self.modifiers, EventHotKeyID(signature: OSType(0x4F564452), id: 1), GetApplicationEventTarget(), 0, &reference)
    }
}
