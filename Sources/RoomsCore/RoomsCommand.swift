import Foundation

public enum RoomsCommand: Equatable, Sendable {
    case walk(room: String, layout: LayoutKind?)
    case showEverything
    case palette
    case newRoom(name: String)
    case addPreset(id: String)

    public static let scheme = "rooms"

    public init?(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == Self.scheme else { return nil }
        let path = c.path.split(separator: "/").map(String.init)
        switch c.host?.lowercased() {
        case "room":
            guard path.count == 1, let key = path.first, !key.isEmpty else { return nil }
            let layout = c.queryItems?.first { $0.name == "layout" }?.value
            if let layout, LayoutKind(rawValue: layout) == nil { return nil }
            self = .walk(room: key, layout: layout.flatMap(LayoutKind.init(rawValue:)))
        case "show-everything" where path.isEmpty:
            self = .showEverything
        case "palette" where path.isEmpty:
            self = .palette
        case "new" where path.isEmpty:
            let name = c.queryItems?.first { $0.name == "name" }?.value ?? ""
            self = .newRoom(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        case "preset":
            guard path.count == 1, let id = path.first, !id.isEmpty else { return nil }
            self = .addPreset(id: id)
        default:
            return nil
        }
    }
}

extension Room {
    public static func find(_ key: String, in rooms: [Room]) -> Room? {
        rooms.first { $0.id == key } ?? rooms.first { Matcher.fold($0.name) == Matcher.fold(key) }
    }
}
