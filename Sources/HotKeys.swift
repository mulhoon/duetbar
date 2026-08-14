import Carbon.HIToolbox
import Foundation

// Global hotkeys via Carbon's RegisterEventHotKey.
//
// This is the old API, but it's the right one: it needs no Accessibility
// permission, and it swallows the keystroke instead of letting it fall through to
// whatever app is in front. NSEvent global monitors and CGEventTap can do neither.

struct HotKeySpec {
    let id: UInt32
    let keyCode: UInt32
    let modifiers: UInt32
    let name: String
    let display: String

    /// Three modifiers, because two-modifier combinations are crowded and
    /// control-option-command is claimed by almost nothing.
    static let base = UInt32(controlKey | optionKey | cmdKey)

    static let muteSpeakers = HotKeySpec(
        id: 1, keyCode: UInt32(kVK_ANSI_M), modifiers: base,
        name: "Mute", display: "⌃⌥⌘M")
    static let dimSpeakers = HotKeySpec(
        id: 2, keyCode: UInt32(kVK_ANSI_D), modifiers: base,
        name: "Dim", display: "⌃⌥⌘D")
    static let volumeUp = HotKeySpec(
        id: 3, keyCode: UInt32(kVK_UpArrow), modifiers: base,
        name: "Volume up", display: "⌃⌥⌘↑")
    static let volumeDown = HotKeySpec(
        id: 4, keyCode: UInt32(kVK_DownArrow), modifiers: base,
        name: "Volume down", display: "⌃⌥⌘↓")

    static let all = [muteSpeakers, dimSpeakers, volumeUp, volumeDown]
}

/// How far one press moves the level.
let hotKeyVolumeStep: Double = 2.0

final class HotKeyManager {
    static let shared = HotKeyManager()

    private var actions: [UInt32: () -> Void] = [:]
    private var registered: [EventHotKeyRef?] = []
    private var handlerInstalled = false

    /// Combinations another app already owns. Carbon can't see system shortcuts,
    /// so an empty list doesn't guarantee every key will actually fire.
    private(set) var unavailable: [HotKeySpec] = []

    private init() {}

    func register(_ spec: HotKeySpec, action: @escaping () -> Void) {
        installHandler()

        var ref: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: OSType(0x44_55_45_54), id: spec.id) // 'DUET'
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers, identifier,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            actions[spec.id] = action
            registered.append(ref)
        } else {
            unavailable.append(spec)
        }
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // A C callback can't capture context, so it goes through the singleton.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size,
                                           nil, &identifier)
            guard status == noErr else { return status }
            DispatchQueue.main.async { HotKeyManager.shared.fire(identifier.id) }
            return noErr
        }, 1, &type, nil, nil)
    }
}
