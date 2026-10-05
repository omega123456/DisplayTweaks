import Foundation

/// Display records in `Env.defaults` (DD-5, ADR e6a117ad): one JSON-encoded `DisplayRecord` per display UUID under
/// the key `display.<UUID>`. The Dev and production bundle IDs keep their records apart.
final class DisplayStore {
    static func key(_ uuid: String) -> String { "display.\(uuid)" }

    /// The stored record, or nil when there is none or it is unreadable (NFR-4: unreadable data gives the defaults).
    func record(for uuid: String) -> DisplayRecord? {
        Env.defaults.data(forKey: Self.key(uuid)).flatMap { try? JSONDecoder().decode(DisplayRecord.self, from: $0) }
    }

    /// Every record of a display DisplayTweaks has disabled, by UUID (ADR 2132bdb2).
    func disabled() -> [String: DisplayRecord] {
        let prefix = Self.key("")
        return Env.defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }.reduce(into: [:]) { out, key in
            let uuid = String(key.dropFirst(prefix.count))
            if let r = record(for: uuid), r.disabledID != nil { out[uuid] = r }
        }
    }

    func save(_ record: DisplayRecord, for uuid: String) {
        Env.defaults.set(try? JSONEncoder().encode(record), forKey: Self.key(uuid))
    }
}
