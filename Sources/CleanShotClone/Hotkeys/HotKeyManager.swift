import AppKit
import Carbon.HIToolbox

enum HotKeyAction: UInt32, CaseIterable {
    case captureArea = 1
    case captureWindow = 2
    case captureFullScreen = 3
    case captureScrolling = 5
    case toggleRecording = 4
    case captureText = 6

    var keyCode: UInt32 {
        switch self {
        case .captureArea:       return UInt32(kVK_ANSI_4)
        case .captureWindow:     return UInt32(kVK_ANSI_2)
        case .captureFullScreen: return UInt32(kVK_ANSI_3)
        case .captureScrolling:  return UInt32(kVK_ANSI_5)
        case .toggleRecording:   return UInt32(kVK_ANSI_6)
        case .captureText:       return UInt32(kVK_ANSI_1)
        }
    }

    /// option + shift
    var modifiers: UInt32 {
        return UInt32(optionKey | shiftKey)
    }
}

final class HotKeyManager {
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    init() {
        installHandler()
    }

    deinit {
        for ref in refs { UnregisterEventHotKey(ref) }
        if let h = eventHandler { RemoveEventHandler(h) }
    }

    func register(_ action: HotKeyAction, handler: @escaping () -> Void) {
        let combo = AppPreferences.defaultHotkeys[action]
            ?? AppPreferences.HotKeyCombo(keyCode: action.keyCode, modifiers: action.modifiers)
        register(action, keyCode: combo.keyCode, modifiers: combo.modifiers, handler: handler)
    }

    func register(_ action: HotKeyAction, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        let id = EventHotKeyID(signature: OSType(0x43534854), id: action.rawValue) // 'CSHT'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("SwiftShot: failed to register hotkey \(action) (status=\(status))")
            return
        }
        refs.append(ref)
        handlers[action.rawValue] = handler
    }

    /// Unregister everything and re-register each action from `prefs.hotkeys`.
    func reload(from prefs: AppPreferences, handlers: [HotKeyAction: () -> Void]) {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        self.handlers.removeAll()
        for (action, handler) in handlers {
            let combo = prefs.hotkeys[action]
                ?? AppPreferences.defaultHotkeys[action]
                ?? AppPreferences.HotKeyCombo(keyCode: action.keyCode, modifiers: action.modifiers)
            register(action, keyCode: combo.keyCode, modifiers: combo.modifiers, handler: handler)
        }
    }

    private func installHandler() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if status == noErr, let handler = manager.handlers[id.id] {
                DispatchQueue.main.async { handler() }
            }
            return noErr
        }, 1, &eventSpec, selfPtr, &eventHandler)
    }
}
