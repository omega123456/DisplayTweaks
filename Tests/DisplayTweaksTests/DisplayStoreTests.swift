import Foundation
import Testing
@testable import DisplayTweaks

extension Desktop {
    @MainActor @Suite struct DisplayStoreTests {
        let h = Harness()
        let store = DisplayStore()

        @Test func roundTrip() throws {
            #expect(store.record(for: "A") == nil)
            let record = DisplayRecord(choice: .on, name: "DELL S2725DC")
            store.save(record, for: "A")
            #expect(store.record(for: "A") == record)
            #expect(store.record(for: "B") == nil)
            store.save(DisplayRecord(choice: .off, name: "DELL S2725DC"), for: "A")
            #expect(store.record(for: "A")?.choice == .off)

            // DD-5: JSON under display.<UUID>, with the schema version and no mode number or native size.
            let json = try #require(h.defaults.data(forKey: "display.A"))
            let keys = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any]).keys
            #expect(Set(keys) == ["choice", "name", "version"])
        }

        @Test func unreadableData() {
            h.defaults.set(Data("not json".utf8), forKey: "display.A")
            #expect(store.record(for: "A") == nil)
            h.defaults.set(Data(#"{"choice":"maybe","name":"X","version":1}"#.utf8), forKey: "display.A")
            #expect(store.record(for: "A") == nil)
            h.defaults.set("a string", forKey: "display.A")
            #expect(store.record(for: "A") == nil)
        }
    }
}
