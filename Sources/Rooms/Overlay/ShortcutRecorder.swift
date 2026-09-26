import AppKit
import QuartzCore
import RoomsCore

final class ShortcutRecorder: NSView {
    var onClick: () -> Void = {}
    private let title = NSTextField(labelWithString: "Press a new shortcut")
    private var recording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.alignment = .center
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setAccessibilityElement(false)
        addSubview(title)
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: centerXAnchor),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Keyboard shortcut")
        setAccessibilityHelp("Click, then press the keys you want.")
        toolTip = "Click, then press the keys you want."
        updateChrome()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(title.intrinsicContentSize.width + 28, 148), height: 30)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateChrome()
    }

    func display(_ shortcut: PaletteShortcut) {
        title.stringValue = shortcut.label
        title.textColor = .labelColor
        setAccessibilityValue(shortcut.spoken)
        invalidateIntrinsicContentSize()
    }

    func displayPrompt(_ text: String) {
        title.stringValue = text
        title.textColor = .secondaryLabelColor
        setAccessibilityValue("Not set")
        invalidateIntrinsicContentSize()
    }

    func setRecording(_ on: Bool) {
        recording = on
        updateChrome()
    }

    override func mouseDown(with event: NSEvent) { onClick() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    private func updateChrome() {
        let border = recording ? NSColor.controlAccentColor : NSColor.separatorColor
        let fill = NSColor.controlBackgroundColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = border.cgColor
            layer?.backgroundColor = fill.cgColor
        }
        layer?.borderWidth = recording ? 2 : 1
    }
}

final class ShortcutEditor: NSStackView {
    private let recorder = ShortcutRecorder()
    private let conflictLabel = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let suggestionRow = NSStackView()
    private var suggestionShortcuts: [PaletteShortcut] = []
    private var register: (PaletteShortcut) -> String? = { _ in nil }
    private var suspend: () -> Void = {}
    private var restore: () -> Void = {}
    private var onRegistered: (PaletteShortcut) -> Void = { _ in }
    private var reserved: [PaletteShortcut: String] = [:]
    private var committed: PaletteShortcut?
    private var keepSuggestions = false
    private var recording = false
    private var prompt = "Press shortcut…"
    private var monitor: Any?

    var isRecording: Bool { recording }

    init(caption: String?) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        translatesAutoresizingMaskIntoConstraints = false

        conflictLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        conflictLabel.textColor = .labelColor
        conflictLabel.isHidden = true
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.isHidden = true

        suggestionRow.orientation = .horizontal
        suggestionRow.alignment = .centerY
        suggestionRow.spacing = 8
        suggestionRow.isHidden = true

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        if let caption {
            let label = NSTextField(labelWithString: caption)
            label.font = .systemFont(ofSize: 14, weight: .semibold)
            label.textColor = .labelColor
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(label)
            row.addArrangedSubview(spacer)
            row.addArrangedSubview(recorder)
        } else {
            let leading = NSView()
            let trailing = NSView()
            leading.setContentHuggingPriority(.defaultLow, for: .horizontal)
            trailing.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(leading)
            row.addArrangedSubview(recorder)
            row.addArrangedSubview(trailing)
            leading.widthAnchor.constraint(equalTo: trailing.widthAnchor).isActive = true
        }

        addArrangedSubview(conflictLabel)
        addArrangedSubview(row)
        addArrangedSubview(suggestionRow)
        addArrangedSubview(messageLabel)
        pin(row)
        pin(conflictLabel)
        pin(messageLabel)
        recorder.onClick = { [weak self] in self?.toggle() }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let width = bounds.width
        if conflictLabel.preferredMaxLayoutWidth != width {
            conflictLabel.preferredMaxLayoutWidth = width
            messageLabel.preferredMaxLayoutWidth = width
        }
    }

    func configure(committed: PaletteShortcut?, conflict: String?, reserved: [PaletteShortcut: String], keepSuggestions: Bool = false, register: @escaping (PaletteShortcut) -> String?, suspend: @escaping () -> Void, restore: @escaping () -> Void, onRegistered: @escaping (PaletteShortcut) -> Void) {
        endListening()
        self.committed = committed
        self.keepSuggestions = keepSuggestions
        self.reserved = reserved
        self.register = register
        self.suspend = suspend
        self.restore = restore
        self.onRegistered = onRegistered
        conflictLabel.stringValue = conflict ?? ""
        conflictLabel.isHidden = conflict == nil
        messageLabel.isHidden = true
        rebuildSuggestions()
        showSuggestionRow()
        if committed == nil, conflict != nil { begin() }
        else { showCommittedOrPrompt() }
    }

    func stop() {
        guard recording else { return }
        endListening()
        messageLabel.isHidden = true
        showCommittedOrPrompt()
        showSuggestionRow()
        restore()
    }

    private func pin(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    private func toggle() {
        if recording { stop() } else { begin() }
    }

    private func begin() {
        recording = true
        prompt = committed == nil ? "Press a new shortcut" : "Press shortcut…"
        messageLabel.isHidden = true
        showSuggestionRow(recording: true)
        suspend()
        recorder.setRecording(true)
        recorder.displayPrompt(prompt)
        installMonitor()
    }

    private func attempt(_ shortcut: PaletteShortcut) {
        let wasRecording = recording
        endListening()
        if let reason = shortcut.rejection(reserved: reserved) {
            showProblem(reason)
            showCommittedOrPrompt()
            if wasRecording { restore() }
            return
        }
        if let reason = register(shortcut) {
            showProblem(reason)
            markInUse(shortcut)
            showCommittedOrPrompt()
            restore()
            return
        }
        committed = shortcut
        recorder.display(shortcut)
        messageLabel.isHidden = true
        conflictLabel.isHidden = true
        showSuggestionRow()
        onRegistered(shortcut)
    }

    private func endListening() {
        recording = false
        removeMonitor()
        recorder.setRecording(false)
    }

    private func showSuggestionRow(recording: Bool = false) {
        let visible = !suggestionShortcuts.isEmpty && (keepSuggestions || recording || committed == nil)
        suggestionRow.isHidden = !visible
    }

    private func showCommittedOrPrompt() {
        if let committed { recorder.display(committed) }
        else { recorder.displayPrompt("Press a new shortcut") }
    }

    private func showProblem(_ text: String) {
        messageLabel.stringValue = text
        messageLabel.isHidden = false
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, 8, -8, 5, -5, 0]
        animation.duration = 0.35
        recorder.layer?.add(animation, forKey: "shake")
    }

    private func rebuildSuggestions() {
        suggestionRow.arrangedSubviews.forEach {
            suggestionRow.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        suggestionShortcuts = PaletteShortcut.suggestions(reserved: Set(reserved.keys))
        for (index, shortcut) in suggestionShortcuts.enumerated() {
            let button = NSButton(title: shortcut.label, target: self, action: #selector(suggestionClicked(_:)))
            button.bezelStyle = .push
            button.controlSize = .regular
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.tag = index
            button.setAccessibilityLabel(shortcut.spoken)
            suggestionRow.addArrangedSubview(button)
        }
    }

    private func markInUse(_ shortcut: PaletteShortcut) {
        guard let index = suggestionShortcuts.firstIndex(of: shortcut),
              let button = suggestionRow.arrangedSubviews[index] as? NSButton else { return }
        button.isEnabled = false
        button.title = "\(shortcut.label) · in use"
    }

    @objc private func suggestionClicked(_ sender: NSButton) {
        guard suggestionShortcuts.indices.contains(sender.tag) else { return }
        attempt(suggestionShortcuts[sender.tag])
    }

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            var consume = false
            MainActor.assumeIsolated { consume = self.handle(event) }
            return consume ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        self.monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard recording, window?.isKeyWindow == true else { return false }
        if event.type == .flagsChanged {
            let held = PaletteShortcut.Modifiers(event.modifierFlags)
            recorder.displayPrompt(held.symbols.isEmpty ? prompt : held.symbols)
            return true
        }
        if event.isARepeat { return true }
        let code = UInt16(event.keyCode)
        if Self.modifierKeyCodes.contains(code) { return true }
        let mods = PaletteShortcut.Modifiers(event.modifierFlags)
        if code == PaletteShortcut.Key.escape, !mods.includesPaletteModifier {
            stop()
            return true
        }
        attempt(PaletteShortcut(keyCode: code, modifiers: mods))
        return true
    }

    private static let modifierKeyCodes: Set<UInt16> = [0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F]
}

extension PaletteShortcut.Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers = Self()
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        self = modifiers
    }
}

final class OverlayPanel: NSPanel {
    var onCancel: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }
}

@MainActor
func overlayLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.isSelectable = false
    return field
}

@MainActor
func makeOverlayPanel(width: CGFloat, content: NSView) -> OverlayPanel {
    let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                             styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
    // Panels hide whenever their app isn't active, and at launch Finder still is.
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    content.translatesAutoresizingMaskIntoConstraints = false
    content.widthAnchor.constraint(equalToConstant: width).isActive = true
    if let glass = Glass.surface(content, tint: NSColor.windowBackgroundColor.withAlphaComponent(0.85)) {
        panel.contentView = glass
        // Glass draws its own edge; the window's rectangular shadow would show as a
        // square border behind the rounded corners.
        panel.hasShadow = false
    } else {
        let material = NSVisualEffectView()
        material.material = .popover
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 24
        material.layer?.masksToBounds = true
        material.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            content.topAnchor.constraint(equalTo: material.topAnchor),
            content.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])
        panel.contentView = material
        panel.hasShadow = true
    }
    return panel
}

@MainActor
func presentOverlay(_ panel: NSPanel) {
    let mouse = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
    panel.contentView?.layoutSubtreeIfNeeded()
    let size = panel.contentView?.fittingSize ?? NSSize(width: panel.frame.width, height: 400)
    let visible = screen.visibleFrame
    panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + visible.height * 0.1, width: size.width, height: size.height), display: true)
    // No fade: at launch the app isn't active yet, and a panel that starts
    // transparent can stay that way.
    panel.alphaValue = 1
    NSApp.activate()
    panel.makeKeyAndOrderFront(nil)
    panel.orderFrontRegardless()
}

@MainActor
final class ShortcutChooser: NSObject {
    private var panel: NSPanel?
    private var editor: ShortcutEditor?

    func close() {
        editor?.stop()
        panel?.orderOut(nil)
    }

    func show(shortcut: PaletteShortcut?, conflict: String?, reserved: [PaletteShortcut: String], register: @escaping (PaletteShortcut) -> String?, suspend: @escaping () -> Void, restore: @escaping () -> Void) {
        editor?.stop()
        let editor = ShortcutEditor(caption: nil)
        self.editor = editor
        editor.configure(committed: shortcut, conflict: conflict, reserved: reserved, keepSuggestions: true, register: register, suspend: suspend, restore: restore, onRegistered: { _ in })

        let title = overlayLabel("Keyboard Shortcut", size: 24, weight: .semibold, color: .labelColor)
        let explanation = overlayLabel("This opens the room list from anywhere.", size: 14, weight: .regular, color: .secondaryLabelColor)
        let done = NSButton(title: "Done", target: self, action: #selector(doneClicked))
        done.bezelStyle = .push
        done.controlSize = .large
        done.bezelColor = .controlAccentColor
        done.keyEquivalent = "\r"
        let actions = NSStackView(views: [NSView(), done])
        actions.spacing = 8

        let stack = NSStackView(views: [title, editor, explanation, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.setCustomSpacing(8, after: title)
        stack.setCustomSpacing(8, after: editor)
        stack.setCustomSpacing(24, after: explanation)
        stack.edgeInsets = NSEdgeInsets(top: 32, left: 24, bottom: 24, right: 24)
        for view in [title, editor, explanation, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }

        let panel = makeOverlayPanel(width: 420, content: stack)
        panel.onCancel = { [weak self] in
            guard let self else { return }
            if self.editor?.isRecording == true { self.editor?.stop() }
            else { self.close() }
        }
        self.panel?.orderOut(nil)
        self.panel = panel
        presentOverlay(panel)
    }

    @objc private func doneClicked() { close() }
}
