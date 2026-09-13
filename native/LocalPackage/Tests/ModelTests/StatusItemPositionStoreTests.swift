import Foundation
import Testing

@testable import Model

// The status item carries a stable autosaveName, so macOS keys its slot off a
// name we control instead of AppKit's positional "Item-0". These pin the
// upgrade path (a drag recorded under the old key is not thrown away, and is
// not re-applied later over a newer one) and the single-source-of-truth rule:
// the legacy key is a migration input, never a second copy to read back.
@Suite struct StatusItemPositionStoreTests {
    private let fallback = 200.0

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "tokcat.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func withStore(
        _ body: (StatusItemPositionStore, UserDefaults) throws -> Void
    ) throws {
        let (defaults, name) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        try body(StatusItemPositionStore(defaults: defaults), defaults)
    }

    @Test func derivesThePositionKeyFromTheAutosaveName() {
        #expect(StatusItemPositionStore.autosaveName == "TokcatStatusItem")
        #expect(StatusItemPositionStore.positionKey
            == "NSStatusItem Preferred Position TokcatStatusItem")
        #expect(StatusItemPositionStore.legacyPositionKey
            == "NSStatusItem Preferred Position Item-0")
    }

    // Upgrading from a build with no autosaveName: the drag lives under the
    // generated key and has to move over before the item is created.
    @Test func migratesALegacyDragOntoTheAutosaveKey() throws {
        try withStore { store, defaults in
            defaults.set(640.0, forKey: StatusItemPositionStore.legacyPositionKey)
            store.migrateLegacyPositionIfNeeded()
            #expect(defaults.object(
                forKey: StatusItemPositionStore.positionKey) as? Double == 640)
            #expect(store.storedPosition == 640)
        }
    }

    @Test func migrationNeverOverwritesTheAutosaveKey() throws {
        try withStore { store, defaults in
            defaults.set(900.0, forKey: StatusItemPositionStore.positionKey)
            defaults.set(640.0, forKey: StatusItemPositionStore.legacyPositionKey)
            store.migrateLegacyPositionIfNeeded()
            #expect(store.storedPosition == 900)
        }
    }

    @Test func migrationIsANoOpWithNothingStored() throws {
        try withStore { store, defaults in
            store.migrateLegacyPositionIfNeeded()
            #expect(defaults.object(
                forKey: StatusItemPositionStore.positionKey) as? Double == nil)
            #expect(store.storedPosition == nil)
        }
    }

    // Removing a status item clears the autosave key, so "that key is empty"
    // cannot stand in for "we never migrated" — a launch starting from a cleared
    // key would otherwise copy the stale Item-0 value back over a newer drag.
    @Test func migrationRunsOnlyOnceEvenIfTheAutosaveKeyIsClearedLater() throws {
        try withStore { store, defaults in
            defaults.set(640.0, forKey: StatusItemPositionStore.legacyPositionKey)
            store.migrateLegacyPositionIfNeeded()
            #expect(store.storedPosition == 640)

            // The user drags to 900; a rebuild's removal then clears the key.
            defaults.set(900.0, forKey: StatusItemPositionStore.positionKey)
            defaults.removeObject(forKey: StatusItemPositionStore.positionKey)
            store.migrateLegacyPositionIfNeeded()
            #expect(store.storedPosition == nil)
        }
    }

    // The legacy key is a migration input, not a fallback source. Reading it
    // back as "the stored position" is what let a rebuild seat a stale value the
    // user had already dragged away from.
    @Test func aLegacyValueAloneIsNotAStoredPosition() throws {
        try withStore { store, defaults in
            defaults.set(720.0, forKey: StatusItemPositionStore.legacyPositionKey)
            #expect(store.storedPosition == nil)
            store.migrateLegacyPositionIfNeeded()
            #expect(store.storedPosition == 720)
        }
    }

    @Test func seatingRecordsTheValueAsOursAndLeavesTheLegacyKeyAlone() throws {
        try withStore { store, defaults in
            defaults.set(640.0, forKey: StatusItemPositionStore.legacyPositionKey)
            store.seat(at: fallback)
            #expect(defaults.object(
                forKey: StatusItemPositionStore.positionKey) as? Double == fallback)
            #expect(defaults.object(
                forKey: StatusItemPositionStore.seededPositionKey)
                as? Double == fallback)
            #expect(store.seededPosition == fallback)
            // Never written: macOS does not maintain it once autosaveName is set.
            #expect(defaults.object(
                forKey: StatusItemPositionStore.legacyPositionKey)
                as? Double == 640)
        }
    }

    // Putting the user's own position back must not claim it. If `restore`
    // stamped the seeded marker, the next rebuild would read 500 as a value
    // Tokcat seated and drop the fallback on top of it — the #94 snap-back,
    // one rebuild later.
    @Test func restoringAUserPositionDoesNotClaimItAsOurs() throws {
        try withStore { store, defaults in
            store.seat(at: fallback)
            store.restore(at: 500)
            #expect(store.storedPosition == 500)
            #expect(store.seededPosition == fallback)
            #expect(defaults.object(
                forKey: StatusItemPositionStore.seededPositionKey)
                as? Double == fallback)
        }
    }

    // The whole point of restoring: the removal cleared the key, and the value
    // has to be back on file before the replacement item is created or the bar
    // parks it off-screen.
    @Test func restoringRepopulatesAClearedKey() throws {
        try withStore { store, _ in
            // Nothing on file: the removal that starts the rebuild cleared it.
            #expect(store.storedPosition == nil)
            store.restore(at: 611)
            #expect(store.storedPosition == 611)
        }
    }
}
