import AppKit
import RoomsCore

/// Walks into a room. With Accessibility allowed, rooms are made of windows:
/// the room's windows are placed, the rest are parked or hidden. Without it,
/// Rooms falls back to whole apps (show the room's apps, hide the others).
/// Either way, nothing is ever closed.
@MainActor
enum Switcher {
    struct Report {
        var launched: [String] = []
        var missing: [String] = []
        var arranged: WindowEngine.Report?
        var rested = 0
    }

    /// The room comes to `display`; `others`, the rooms out on other displays, stay.
    static func walk(into room: Room, on display: String, keeping others: [Room] = [], engine: WindowEngine) async -> Report {
        var report = Report()
        let ws = NSWorkspace.shared

        // 1. Launch the room's apps that aren't running.
        var bundles: [String] = []
        var launchedIDs: Set<String> = []
        for id in room.windows.map(\.bundleID) + room.apps.map(\.bundleID) where !bundles.contains(id) { bundles.append(id) }
        for id in bundles where NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
            guard let url = ws.urlForApplication(withBundleIdentifier: id) else {
                report.missing.append(room.apps.first { $0.bundleID == id }?.name ?? id)
                continue
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try? await ws.openApplication(at: url, configuration: config)
            report.launched.append(url.deletingPathExtension().lastPathComponent)
            launchedIDs.insert(id)
        }

        // 2. Arrange.
        if AX.isTrusted {
            report.arranged = await engine.arrange(room, on: display, keeping: others, launched: launchedIDs)
        } else {
            let wanted = Set(bundles + others.flatMap { $0.windows.map(\.bundleID) + $0.apps.map(\.bundleID) })
            for app in ws.runningApplications where app.activationPolicy == .regular && app != .current {
                if wanted.contains(app.bundleIdentifier ?? "") { app.unhide() } else if !app.isHidden, app.hide() { report.rested += 1 }
            }
        }

        // 3. Land in the room's first window (or first app) so typing goes there.
        if let first = bundles.first, let url = ws.urlForApplication(withBundleIdentifier: first) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await ws.openApplication(at: url, configuration: config)
        }
        return report
    }
}
