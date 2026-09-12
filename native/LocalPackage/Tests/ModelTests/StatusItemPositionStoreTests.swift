import Foundation
import Testing

@testable import Model

// The status item now carries a stable autosaveName, so macOS keys its slot off
// a name we control instead of AppKit's positional "Item-0". These pin the
// upgrade path (a drag recorded under the old key is not thrown away) and the
// both-keys handling that keeps hidden-item recovery working if a macOS version
// ignores the autosave name.
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

    // If macOS keeps maintaining the generated key, a drag recorded there still
    // has to read as a drag — the value that differs from what we seated wins.
    @Test func prefersAStoredValueThatIsNotTheOneWeSeated() throws {
        try withStore { store, defaults in
            store.seat(at: fallback)
            #expect(store.storedPosition == fallback)
            #expect(store.seededPosition == fallback)
            // AppKit records the user's drag under the legacy key only.
            defaults.set(720.0, forKey: StatusItemPositionStore.legacyPositionKey)
            #expect(store.storedPosition == 720)
        }
    }

    // The mirror image: the autosave key is the live one and the legacy key is
    // the stale copy seating left behind.
    @Test func prefersTheAutosaveKeyWhenThatIsWhereTheDragLanded() throws {
        try withStore { store, defaults in
            store.seat(at: fallback)
            defaults.set(720.0, forKey: StatusItemPositionStore.positionKey)
            #expect(store.storedPosition == 720)
        }
    }

    // Seating writes both keys: a fallback written only to the autosave key
    // would silently fail to move the item on a macOS version that ignores it.
    @Test func seatingWritesBothKeysAndRecordsTheValueAsOurs() throws {
        try withStore { store, defaults in
            store.seat(at: fallback)
            #expect(defaults.object(
                forKey: StatusItemPositionStore.positionKey) as? Double == fallback)
            #expect(defaults.object(
                forKey: StatusItemPositionStore.legacyPositionKey)
                as? Double == fallback)
            #expect(defaults.object(
                forKey: StatusItemPositionStore.seededPositionKey)
                as? Double == fallback)
        }
    }
}
