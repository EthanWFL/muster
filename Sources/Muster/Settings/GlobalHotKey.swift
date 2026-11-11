import Carbon.HIToolbox
import Foundation

/// Carbon hotkey instead of a global event monitor: no Accessibility permission needed.
@MainActor
final class GlobalHotKey {
    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let hotKeyID = EventHotKeyID(signature: OSType(0x4D535452), id: 1)

    func setEnabled(_ enabled: Bool) {
        if enabled { register() } else { unregister() }
    }

    private func register() {
        guard hotKeyRef == nil else { return }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_A),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            SettingsStore.shared.hotKeyError = L10n.t("Hotkey registration failed: %@", "⌃⌥A")
            return
        }
        hotKeyRef = ref

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        if handlerStatus != noErr {
            unregister()
            SettingsStore.shared.hotKeyError = L10n.t("Hotkey registration failed: %@", "⌃⌥A")
        } else {
            SettingsStore.shared.hotKeyError = nil
        }
    }

    private func unregister() {
        if let handlerRef { RemoveEventHandler(handlerRef) }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        handlerRef = nil
        hotKeyRef = nil
    }

    private static let callback: EventHandlerUPP = { _, _, userData in
        guard let userData else { return noErr }
        let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
        DispatchQueue.main.async { hotKey.onTrigger?() }
        return noErr
    }
}
