//
//  GlobalHotKey.swift
//  DualCast Switcher
//
//  Process-global hotkeys via Carbon RegisterEventHotKey. These fire even
//  while the app is backgrounded and need no Accessibility permission —
//  which makes them perfect targets for Elgato Stream Deck's built-in
//  "Hotkey" action on the same Mac.
//
//  Carbon event handlers are delivered on the main thread, and all public
//  API here is main-thread confined, so no extra locking is required.
//

import Carbon.HIToolbox
import Foundation

@MainActor
final class GlobalHotKey {
    struct Binding {
        let id: UInt32
        let keyCode: UInt32
        let modifiers: UInt32
        let action: @MainActor () -> Void
    }

    /// 'DCSW' — identifies our hotkeys in Carbon events.
    private static let signature: OSType = 0x4443_5357

    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef?] = [:]
    private var handlerInstalled = false

    /// Standard modifier set for switcher hotkeys: ⌃⌥⌘.
    static let switcherModifiers = UInt32(controlKey | optionKey | cmdKey)

    func register(_ binding: Binding) {
        if !handlerInstalled {
            installHandler()
            handlerInstalled = true
        }
        unregister(id: binding.id)
        actions[binding.id] = binding.action

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: binding.id)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        refs[binding.id] = ref
    }

    func unregister(id: UInt32) {
        if let ref = refs[id] {
            UnregisterEventHotKey(ref)
            refs[id] = nil
        }
        actions[id] = nil
    }

    func unregisterAll() {
        for id in Array(refs.keys) {
            unregister(id: id)
        }
    }

    // MARK: - Carbon event handling

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }

                let this = Unmanaged<GlobalHotKey>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                let action = MainActor.assumeIsolated { this.actions[hotKeyID.id] }
                if let action {
                    Task { @MainActor in action() }
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
    }
}
