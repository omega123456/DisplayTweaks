import Foundation

/// Display records in `Env.defaults` (DD-5, ADR e6a117ad): one JSON-encoded `DisplayRecord` per display UUID under
/// the key `display.<UUID>`. The Dev and production bundle IDs keep their records apart.
final class DisplayStore {
    static func key(_ uuid: String) -> String { "display.\(uuid)" }

    /// The stored record, or nil when there is none or it is unreadable (NFR-4: unreadable data gives the defaults).
    func record(for uuid: String) -> DisplayRecord? {
        Env.defaults.data(forKey: Self.key(uuid)).flatMap { try? JSONDecoder().decode(DisplayRecord.self, from: $0) }
    }

    func save(_ record: DisplayRecord, for uuid: String) {
        Env.defaults.set(try? JSONEncoder().encode(record), forKey: Self.key(uuid))
    }
}
