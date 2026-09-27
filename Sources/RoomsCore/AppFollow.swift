import Foundation

/// Which room to follow an app into when it comes to the front some other way
/// (⌘Tab, the Dock, a launcher, a click).
public enum AppFollow {
    /// The room to walk into when `bundleID` comes to the front, or nil to stay put.
    /// Nil when the app is in the current room or in no room. An app shared by
    /// several rooms (Buzz, a browser) goes to whichever of them you were in most
    /// recently; nil if you've been in none of them, rather than guess.
    public static func room(for bundleID: String, in rooms: [Room], current: String?,
                            recency: [String: Date] = [:]) -> Room? {
        let holding = rooms.filter { $0.contains(bundleID) }
        if let current, holding.contains(where: { $0.id == current }) { return nil }
        if holding.count == 1 { return holding[0] }
        return holding
            .compactMap { room in recency[room.id].map { (room, $0) } }
            .max { $0.1 < $1.1 }?.0
    }
}

extension Room {
    /// The app has a window in this room, or the room is made of apps and lists it.
    public func contains(_ bundleID: String) -> Bool {
        windows.contains { $0.bundleID == bundleID } || apps.contains { $0.bundleID == bundleID }
    }
}
