import Testing
@testable import RoomsCore

@Test func defaultsToOptionSpace() {
    #expect(PaletteShortcut.optionSpace.label == "⌥ Space")
    #expect(PaletteShortcut.optionSpace.spoken == "Option Space")
    #expect(PaletteShortcut.load(keyCode: nil, modifiers: nil, legacyID: nil) == .optionSpace)
    #expect(PaletteShortcut.load(keyCode: nil, modifiers: nil, legacyID: "option-space") == .optionSpace)
    #expect(PaletteShortcut.load(keyCode: nil, modifiers: nil, legacyID: "nope") == .optionSpace)
}

@Test func loadsLegacyPresets() {
    #expect(PaletteShortcut.load(keyCode: nil, modifiers: nil, legacyID: "control-option-space") == .controlOptionSpace)
    #expect(PaletteShortcut.load(keyCode: nil, modifiers: nil, legacyID: "control-option-r") == .controlOptionR)
    #expect(PaletteShortcut.controlOptionR.label == "⌃⌥ R")
    #expect(PaletteShortcut.controlOptionShiftSpace.label == "⌃⌥⇧ Space")
}

@Test func storedChordWinsOverLegacyID() {
    let custom = PaletteShortcut(keyCode: PaletteShortcut.Key.r, modifiers: .command)
    let loaded = PaletteShortcut.load(keyCode: Int(custom.keyCode), modifiers: Int(custom.modifiers.rawValue), legacyID: "option-space")
    #expect(loaded == custom)
    #expect(loaded.label == "⌘ R")
}

@Test func partialStoredChordFallsBack() {
    #expect(PaletteShortcut.load(keyCode: 15, modifiers: nil, legacyID: "control-option-r") == .controlOptionR)
    #expect(PaletteShortcut.load(keyCode: nil, modifiers: 2, legacyID: nil) == .optionSpace)
}

@Test func writesModifierSymbolsInStandardOrder() {
    let chord = PaletteShortcut(keyCode: PaletteShortcut.Key.r, modifiers: [.command, .shift, .option, .control])
    #expect(chord.label == "⌃⌥⇧⌘ R")
    #expect(chord.spoken == "Control Option Shift Command R")
    let arrow = PaletteShortcut(keyCode: PaletteShortcut.Key.leftArrow, modifiers: [.control, .option])
    #expect(arrow.label == "⌃⌥ ←")
    #expect(arrow.spoken == "Control Option Left Arrow")
}

@Test func rejectsChordsThatWouldSwallowTyping() {
    let bare = PaletteShortcut(keyCode: PaletteShortcut.Key.space, modifiers: [])
    let shiftOnly = PaletteShortcut(keyCode: PaletteShortcut.Key.r, modifiers: .shift)
    #expect(bare.rejection(reserved: [:]) == "Add Control, Option, or Command")
    #expect(shiftOnly.rejection(reserved: [:]) == "Add Control, Option, or Command")
    #expect(PaletteShortcut.optionSpace.rejection(reserved: [:]) == nil)
    #expect(PaletteShortcut.controlOptionShiftSpace.rejection(reserved: [:]) == nil)
}

@Test func rejectsEscapeEvenWithModifiers() {
    let chord = PaletteShortcut(keyCode: PaletteShortcut.Key.escape, modifiers: .command)
    #expect(chord.rejection(reserved: [:]) == "Esc closes panels")
}

@Test func rejectsChordsRoomsAlreadyUses() {
    let snap = PaletteShortcut.controlOptionSpace
    let reason = "Rooms uses this for window snapping"
    #expect(snap.rejection(reserved: [snap: reason]) == reason)
}

@Test func suggestionsSkipReservedChords() {
    let offered = PaletteShortcut.suggestions(reserved: [.controlOptionR])
    #expect(offered == [.controlOptionSpace, .controlOptionShiftSpace])
}
