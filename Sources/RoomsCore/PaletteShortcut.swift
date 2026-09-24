import Foundation

public struct PaletteShortcut: Equatable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: Modifiers

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)

        public var symbols: String {
            var text = ""
            if contains(.control) { text += "⌃" }
            if contains(.option) { text += "⌥" }
            if contains(.shift) { text += "⇧" }
            if contains(.command) { text += "⌘" }
            return text
        }

        public var includesPaletteModifier: Bool {
            contains(.control) || contains(.option) || contains(.command)
        }
    }

    public enum Key {
        public static let space: UInt16 = 0x31
        public static let r: UInt16 = 0x0F
        public static let escape: UInt16 = 0x35
        public static let leftArrow: UInt16 = 0x7B
    }

    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let optionSpace = PaletteShortcut(keyCode: Key.space, modifiers: .option)
    public static let controlOptionSpace = PaletteShortcut(keyCode: Key.space, modifiers: [.control, .option])
    public static let controlOptionR = PaletteShortcut(keyCode: Key.r, modifiers: [.control, .option])
    public static let controlOptionShiftSpace = PaletteShortcut(keyCode: Key.space, modifiers: [.control, .option, .shift])

    public static func suggestions(reserved: Set<PaletteShortcut>) -> [PaletteShortcut] {
        [controlOptionSpace, controlOptionR, controlOptionShiftSpace].filter { !reserved.contains($0) }
    }

    public var label: String {
        let name = Self.naming(keyCode).visible
        let symbols = modifiers.symbols
        return symbols.isEmpty ? name : symbols + " " + name
    }

    public var spoken: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Control") }
        if modifiers.contains(.option) { parts.append("Option") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Command") }
        parts.append(Self.naming(keyCode).spoken)
        return parts.joined(separator: " ")
    }

    public func rejection(reserved: [PaletteShortcut: String]) -> String? {
        if keyCode == Key.escape { return "Esc closes panels" }
        if !modifiers.includesPaletteModifier { return "Add Control, Option, or Command" }
        return reserved[self]
    }

    public static func load(keyCode: Int?, modifiers: Int?, legacyID: String?) -> PaletteShortcut {
        if let keyCode, let modifiers, let code = UInt16(exactly: keyCode), let raw = UInt8(exactly: modifiers) {
            return PaletteShortcut(keyCode: code, modifiers: Modifiers(rawValue: raw))
        }
        switch legacyID {
        case "control-option-space": return .controlOptionSpace
        case "control-option-r": return .controlOptionR
        default: return .optionSpace
        }
    }
}

extension PaletteShortcut {
    fileprivate static func naming(_ keyCode: UInt16) -> (visible: String, spoken: String) {
        if let letter = letters[keyCode] { return (letter, letter) }
        switch keyCode {
        case Key.space: return ("Space", "Space")
        case 0x24: return ("↩", "Return")
        case 0x30: return ("Tab", "Tab")
        case 0x33: return ("⌫", "Delete")
        case Key.escape: return ("Esc", "Escape")
        case 0x75: return ("⌦", "Forward Delete")
        case Key.leftArrow: return ("←", "Left Arrow")
        case 0x7C: return ("→", "Right Arrow")
        case 0x7D: return ("↓", "Down Arrow")
        case 0x7E: return ("↑", "Up Arrow")
        case 0x18: return ("=", "Equals")
        case 0x1B: return ("-", "Minus")
        case 0x1E: return ("]", "Right Bracket")
        case 0x21: return ("[", "Left Bracket")
        case 0x27: return ("'", "Quote")
        case 0x29: return (";", "Semicolon")
        case 0x2A: return ("\\", "Backslash")
        case 0x2B: return (",", "Comma")
        case 0x2C: return ("/", "Slash")
        case 0x2F: return (".", "Period")
        case 0x32: return ("`", "Grave")
        case 0x7A: return ("F1", "F1")
        case 0x78: return ("F2", "F2")
        case 0x63: return ("F3", "F3")
        case 0x76: return ("F4", "F4")
        case 0x60: return ("F5", "F5")
        case 0x61: return ("F6", "F6")
        case 0x62: return ("F7", "F7")
        case 0x64: return ("F8", "F8")
        case 0x65: return ("F9", "F9")
        case 0x6D: return ("F10", "F10")
        case 0x67: return ("F11", "F11")
        case 0x6F: return ("F12", "F12")
        default: return ("Key \(keyCode)", "Key \(keyCode)")
        }
    }

    private static let letters: [UInt16: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G", 0x04: "H",
        0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P",
        0x0C: "Q", 0x0F: "R", 0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z",
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7",
        0x1C: "8", 0x19: "9",
    ]
}
