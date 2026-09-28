import AppKit
import ApplicationServices

/// Tells Rooms when the frontmost app moves its focus to another of its own windows
/// (its Window menu, ⌘`, a click). Switching apps doesn't need this: NSWorkspace
/// reports that. Only the frontmost app is watched; the watch moves with it.
@MainActor
final class FocusWatch {
    var onFocusChange: (() -> Void)?
    private var observer: AXObserver?
    private var watchedPID: pid_t = 0

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        if let app = NSWorkspace.shared.frontmostApplication { watch(app) }
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        watch(app)
    }

    private func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard AX.isTrusted, app != .current, pid != watchedPID else { return }
        stop()
        var made: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let watch = Unmanaged<FocusWatch>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watch.onFocusChange?() }
        }
        guard AXObserverCreate(pid, callback, &made) == .success, let made else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(made, AX.app(pid), kAXFocusedWindowChangedNotification as CFString, refcon) == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(made), .defaultMode)
        observer = made
        watchedPID = pid
    }

    private func stop() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        watchedPID = 0
    }
}
