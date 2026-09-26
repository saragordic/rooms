import AppKit
import RoomsCore

/// The first thing a new user sees: what Rooms is and the three steps to a first
/// room. Shown on launch until a room exists; also available from Getting Started.
@MainActor
final class Welcome: NSObject {
    private var panel: NSPanel?
    private var editor: ShortcutEditor?
    private let width: CGFloat = 480
    private var onAllow: () -> Void = {}
    private var registerShortcut: (PaletteShortcut) -> String? = { _ in nil }
    private var suspendShortcut: () -> Void = {}
    private var restoreShortcut: () -> Void = {}
    private var reservedShortcuts: [PaletteShortcut: String] = [:]
    private var nameStep: NSTextField?
    private var layoutStep: NSTextField?
    private var afterStep: NSTextField?
    private var primaryButton: NSButton?
    private var laterButton: NSButton?

    func close() {
        editor?.stop()
        panel?.orderOut(nil)
    }

    func show(shortcut: PaletteShortcut?, conflict: String?, needsAccess: Bool, reserved: [PaletteShortcut: String], register: @escaping (PaletteShortcut) -> String?, suspend: @escaping () -> Void, restore: @escaping () -> Void, onAllow: @escaping () -> Void) {
        editor?.stop()
        panel?.orderOut(nil)
        self.onAllow = onAllow
        self.registerShortcut = register
        self.suspendShortcut = suspend
        self.restoreShortcut = restore
        self.reservedShortcuts = reserved
        let panel = makePanel(shortcut: shortcut, conflict: conflict, needsAccess: needsAccess)
        self.panel = panel
        presentOverlay(panel)
    }

    @objc private func startClicked() { close() }

    @objc private func allowClicked() {
        onAllow()
        close()
    }

    private func makePanel(shortcut: PaletteShortcut?, conflict: String?, needsAccess: Bool) -> NSPanel {
        let editor = ShortcutEditor(caption: "Open Rooms")
        self.editor = editor
        editor.configure(
            committed: shortcut,
            conflict: conflict,
            reserved: reservedShortcuts,
            register: { [weak self] chord in self?.registerShortcut(chord) ?? "Already in use" },
            suspend: { [weak self] in self?.suspendShortcut() },
            restore: { [weak self] in self?.restoreShortcut() },
            onRegistered: { [weak self] chord in
                self?.rewrite(chord.label)
                self?.primaryButton?.isEnabled = true
                if self?.primaryButton?.title == "Get Started" { self?.laterButton?.isHidden = true }
            }
        )

        let title = overlayLabel("Welcome to Rooms", size: 24, weight: .semibold, color: .labelColor)
        let intro = overlayLabel("A room is a set of windows for one project. Walk into a room and its windows come back, laid out neatly. Everything else hides, and nothing is ever closed.",
                                 size: 14, weight: .regular, color: .secondaryLabelColor)

        let phrase = shortcut?.label ?? "the shortcut"
        let open = step(1, "Open the windows for one project.")
        let name = step(2, "Press \(phrase), type a name for the room, and press Enter.")
        let click = step(3, "Click the windows that belong in it, then Create Room.")
        let layout = step(4, "To change the layout, press \(phrase), select the room and press Tab.")
        nameStep = name.body
        layoutStep = layout.body
        let steps = NSStackView(views: [open.row, name.row, click.row, layout.row])
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 16

        let after = overlayLabel("From then on, \(phrase) and the room's name brings it back. Rooms lives in the menu bar.",
                                 size: 14, weight: .regular, color: .secondaryLabelColor)
        afterStep = after

        var views: [NSView] = [title, intro, editor, steps, after]
        if needsAccess {
            views.append(overlayLabel("Rooms needs Accessibility access to move windows. Nothing leaves your Mac.",
                                      size: 14, weight: .semibold, color: .labelColor))
        }

        let hasShortcut = shortcut != nil
        let primary = NSButton(title: needsAccess ? "Allow Accessibility…" : "Get Started", target: self,
                               action: needsAccess ? #selector(allowClicked) : #selector(startClicked))
        primary.bezelStyle = .push
        primary.controlSize = .large
        primary.bezelColor = .controlAccentColor
        primary.keyEquivalent = "\r"
        primary.isEnabled = hasShortcut
        primaryButton = primary
        var buttons: [NSView] = [NSView()]
        if needsAccess || !hasShortcut {
            let later = NSButton(title: "Later", target: self, action: #selector(startClicked))
            later.bezelStyle = .push
            later.controlSize = .large
            buttons.append(later)
            laterButton = later
        }
        buttons.append(primary)
        let actions = NSStackView(views: buttons)
        actions.spacing = 8
        views.append(actions)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.setCustomSpacing(8, after: title)
        stack.setCustomSpacing(24, after: intro)
        stack.setCustomSpacing(24, after: editor)
        stack.setCustomSpacing(24, after: steps)
        stack.setCustomSpacing(24, after: views[views.count - 2])
        stack.edgeInsets = NSEdgeInsets(top: 32, left: 24, bottom: 24, right: 24)
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }

        let panel = makeOverlayPanel(width: width, content: stack)
        panel.onCancel = { [weak self] in
            guard let self else { return }
            if self.editor?.isRecording == true { self.editor?.stop() }
            else { self.startClicked() }
        }
        return panel
    }

    private func rewrite(_ shortcut: String) {
        nameStep?.stringValue = "Press \(shortcut), type a name for the room, and press Enter."
        layoutStep?.stringValue = "To change the layout, press \(shortcut), select the room and press Tab."
        afterStep?.stringValue = "From then on, \(shortcut) and the room's name brings it back. Rooms lives in the menu bar."
    }

    private func step(_ n: Int, _ text: String) -> (row: NSView, body: NSTextField) {
        let number = overlayLabel("\(n)", size: 14, weight: .semibold, color: .controlAccentColor)
        number.alignment = .center
        number.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let body = overlayLabel(text, size: 14, weight: .regular, color: .labelColor)
        let row = NSStackView(views: [number, body])
        row.alignment = .firstBaseline
        row.spacing = 8
        return (row, body)
    }
}
