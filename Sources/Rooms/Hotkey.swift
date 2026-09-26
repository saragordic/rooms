import AppKit
import Carbon.HIToolbox
import RoomsCore

/// A global keyboard shortcut. Carbon hot keys need no permission prompt.
struct Shortcut: Equatable, Sendable {
    let id: String
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String

    /// ⌃⌥1 … ⌃⌥9: straight into a room.
    static func room(_ n: Int) -> Shortcut {
        let codes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        return Shortcut(id: "room-\(n)", keyCode: UInt32(codes[n - 1]), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥\(n)")
    }
}

@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    /// The palette shortcut.
    var onPress: (() -> Void)?
    /// ⌃⌥1…9, with the digit.
    var onRoomKey: ((Int) -> Void)?
    /// Snapping keys, with their index in the list given to `registerSnapKeys`.
    var onSnapKey: ((Int) -> Void)?
    private var snapRefs: [EventHotKeyRef] = []
    private(set) var current: Shortcut?

    private var paletteRef: EventHotKeyRef?
    private var roomRefs: [Int: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private static let signature = OSType(0x524F_4F4D) // 'ROOM'

    /// Returns false when macOS refuses the shortcut (usually another app owns it).
    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        if let paletteRef { UnregisterEventHotKey(paletteRef) }
        paletteRef = nil
        current = nil
        guard let ref = add(shortcut, id: 1) else { return false }
        paletteRef = ref
        current = shortcut
        return true
    }

    func unregisterPalette() {
        if let paletteRef { UnregisterEventHotKey(paletteRef) }
        paletteRef = nil
        current = nil
    }

    /// Registers ⌃⌥n for each digit given; returns the digits macOS refused.
    @discardableResult
    func registerRoomKeys(_ digits: [Int]) -> [Int] {
        roomRefs.values.forEach { UnregisterEventHotKey($0) }
        roomRefs = [:]
        var refused: [Int] = []
        for n in digits where (1...9).contains(n) {
            if let ref = add(.room(n), id: UInt32(100 + n)) { roomRefs[n] = ref } else { refused.append(n) }
        }
        return refused
    }

    /// Registers the snapping keys (or none); returns the labels macOS refused.
    @discardableResult
    func registerSnapKeys(_ shortcuts: [Shortcut]) -> [String] {
        snapRefs.forEach { UnregisterEventHotKey($0) }
        snapRefs = []
        var refused: [String] = []
        for (i, s) in shortcuts.enumerated() {
            if let ref = add(s, id: UInt32(200 + i)) { snapRefs.append(ref) } else { refused.append(s.label) }
        }
        return refused
    }

    private func add(_ shortcut: Shortcut, id: UInt32) -> EventHotKeyRef? {
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.file("Shortcut \(shortcut.label) refused by macOS (\(status)); another app may own it")
            return nil
        }
        return ref
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Carbon delivers hot key events on the main thread.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &key)
            let id = key.id
            MainActor.assumeIsolated {
                if id == 1 { HotkeyCenter.shared.onPress?() }
                else if (101...109).contains(id) { HotkeyCenter.shared.onRoomKey?(Int(id) - 100) }
                else if (200...299).contains(id) { HotkeyCenter.shared.onSnapKey?(Int(id) - 200) }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

extension PaletteShortcut {
    init(_ shortcut: Shortcut) {
        var modifiers = Modifiers()
        let raw = shortcut.modifiers
        if raw & UInt32(controlKey) != 0 { modifiers.insert(.control) }
        if raw & UInt32(optionKey) != 0 { modifiers.insert(.option) }
        if raw & UInt32(shiftKey) != 0 { modifiers.insert(.shift) }
        if raw & UInt32(cmdKey) != 0 { modifiers.insert(.command) }
        self.init(keyCode: UInt16(truncatingIfNeeded: shortcut.keyCode), modifiers: modifiers)
    }

    var carbonModifiers: UInt32 {
        var raw: UInt32 = 0
        if modifiers.contains(.control) { raw |= UInt32(controlKey) }
        if modifiers.contains(.option) { raw |= UInt32(optionKey) }
        if modifiers.contains(.shift) { raw |= UInt32(shiftKey) }
        if modifiers.contains(.command) { raw |= UInt32(cmdKey) }
        return raw
    }
}

extension Shortcut {
    init(_ palette: PaletteShortcut) {
        self.init(id: "palette", keyCode: UInt32(palette.keyCode), modifiers: palette.carbonModifiers, label: palette.label)
    }
}
