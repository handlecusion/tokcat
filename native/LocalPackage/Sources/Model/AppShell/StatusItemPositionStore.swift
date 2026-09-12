import Foundation

// The UserDefaults side of the menu-bar slot: which key holds it, how a
// pre-autosaveName install is migrated, and how a user's Cmd-drag is told
// apart from a value Tokcat seated itself.
//
// macOS persists a status item's slot in "NSStatusItem Preferred Position
// <autosaveName>" and rewrites that same preference when the user Cmd-drags
// the item. Tokcat used to leave `autosaveName` unset and inherit AppKit's
// generated "Item-0" name; the item now carries a stable autosave name and
// this store owns the keys.
//
// One key is the source of truth. Measured on macOS 26: with `autosaveName`
// set, the status bar reads and writes the autosave key only and never touches
// the generated one. The legacy key is a migration input, not a second copy —
// mirroring writes into it produced a value that went stale the moment the user
// dragged, and reading that stale copy back is how a rebuild came to seat a
// position the user never chose.
public struct StatusItemPositionStore {
    /// Stable autosave name for the status item. Also assigned to
    /// `NSStatusItem.autosaveName`, which is what makes `positionKey` the key
    /// macOS actually maintains.
    public static let autosaveName = "TokcatStatusItem"

    /// Where macOS stores the item's spot, derived from the autosave name.
    public static let positionKey = "NSStatusItem Preferred Position \(autosaveName)"

    /// The key AppKit generated for us before the autosave name existed. Read
    /// once, by `migrateLegacyPositionIfNeeded()`, and never written.
    public static let legacyPositionKey = "NSStatusItem Preferred Position Item-0"

    /// The last position Tokcat seated itself; a stored value that differs
    /// from it came from the user.
    public static let seededPositionKey = "TokcatSeededStatusItemPosition"

    /// Marks the one-shot legacy migration as done.
    public static let legacyMigrationKey = "TokcatDidMigrateLegacyStatusItemPosition"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Copies a pre-autosaveName drag onto the autosave key, once.
    ///
    /// Must run *before* the first `NSStatusItem` is created: AppKit reads the
    /// preference when it places the item, so a later write would not take
    /// effect until the next launch.
    ///
    /// The "did it run" marker is what makes this one-shot. "The autosave key
    /// is empty" cannot stand in for it, because removing a status item clears
    /// that key — a launch that happened to start from a cleared key would
    /// otherwise resurrect the stale `Item-0` value over a newer drag.
    public func migrateLegacyPositionIfNeeded() {
        guard !defaults.bool(forKey: Self.legacyMigrationKey) else { return }
        defaults.set(true, forKey: Self.legacyMigrationKey)
        // Never overwrite a position already recorded under the autosave key:
        // a user who has run a build with the autosave name and dragged since
        // owns that value, and `Item-0` is stale by definition.
        guard defaults.object(forKey: Self.positionKey) == nil,
              let legacy = defaults.object(forKey: Self.legacyPositionKey) as? Double
        else { return }
        defaults.set(legacy, forKey: Self.positionKey)
    }

    /// The position macOS currently has on file, read fresh on every rebuild so
    /// a drag performed between two rebuilds is seen.
    ///
    /// Must be read *before* the item is removed: the removal clears this key.
    public var storedPosition: Double? {
        defaults.object(forKey: Self.positionKey) as? Double
    }

    public var seededPosition: Double? {
        defaults.object(forKey: Self.seededPositionKey) as? Double
    }

    /// Seats the item at a position Tokcat chose and records it as ours, so the
    /// next decision knows the value is not a user drag.
    public func seat(at position: Double) {
        defaults.set(position, forKey: Self.positionKey)
        defaults.set(position, forKey: Self.seededPositionKey)
    }

    /// Writes the user's own position back after a rebuild cleared it, without
    /// claiming it as ours.
    ///
    /// The seeded marker is deliberately left alone: stamping a preserved user
    /// position with it would make the next rebuild read that position back as
    /// Tokcat's own and seat the fallback over it, which is the #94 snap-back.
    public func restore(at position: Double) {
        defaults.set(position, forKey: Self.positionKey)
    }
}
