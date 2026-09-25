/// Which room is out on which display. Each display shows at most one room and a room
/// is out on at most one display, so one room can sit on the monitor while another is
/// on the laptop. Walking into a room only replaces the room on its own display.
public struct Desk: Hashable, Sendable {
    /// Display UUID → room id.
    public var rooms: [String: String]
    /// The room you walked into last: the one the menu bar names.
    public var current: String?

    public init(rooms: [String: String] = [:], current: String? = nil) {
        self.rooms = rooms
        self.current = current
    }

    /// The display a room is out on.
    public func display(of room: String) -> String? {
        rooms.first { $0.value == room }?.key
    }

    /// The room walks in on `display`: it leaves any other display it was on, and
    /// replaces whatever room was here.
    public mutating func enter(_ room: String, on display: String) {
        rooms = rooms.filter { $0.value != room }
        rooms[display] = room
        current = room
    }

    /// Rooms out on displays other than `display`, among those still connected: the
    /// ones walking into a room there must leave alone.
    public func others(than display: String, connected: [String]) -> [String: String] {
        rooms.filter { $0.key != display && connected.contains($0.key) }
    }

    /// A room was deleted: it's out nowhere any more.
    public mutating func remove(_ room: String) {
        rooms = rooms.filter { $0.value != room }
        if current == room { current = nil }
    }

    /// Show Everything: no room is out.
    public mutating func clear() {
        rooms = [:]
        current = nil
    }

    /// A display came or went. Rooms on displays still connected stay where they are,
    /// and those whose display is gone step back, except the room you're in: it moves
    /// to the largest display, replacing the room there. When it's the only room out, it
    /// moves to the largest display anyway, so plugging a monitor in brings it there.
    /// (A room you're in that's out nowhere came from a version without displays.)
    public mutating func settle(connected: [String], largest: String) {
        let before = rooms
        rooms = rooms.filter { connected.contains($0.key) }
        guard let current, before.isEmpty || before.values.contains(current), connected.contains(largest) else { return }
        if rooms.values.contains(current), before.count > 1 { return }
        enter(current, on: largest)
    }
}
