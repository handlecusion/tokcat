import Foundation

// The UserDefaults side of the menu-bar slot: which keys hold it, how a
// pre-autosaveName install is migrated, and how a user's Cmd-drag is told
// apart from a value Tokcat seated itself.
//
// macOS persists a status item's slot in "NSStatusItem Preferred Position
// <autosaveName>" and rewrites that same preference when the user Cmd-drags
// the item. Tokcat used to leave `autosaveName` unset and reach for AppKit's
// generated "Item-0" name; that name is positional and is not reliably kept
// across removeStatusItem()/quit, so a drag could be lost on a plain relaunch.
// The item now carries a stable autosave name and this store owns the keys.
//
// Both keys are still read and written. The legacy value is migrated once so
// upgrading users keep the slot they chose, and if a macOS version ignores our
// autosave name and keeps maintaining the generated key, a fallback written
// only to the new key would silently fail to move a parked item.
public struct StatusItemPositionStore {
    /// Stable autosave name for the status item. Also assigned to
    /// `NSStatusItem.autosaveName`, which is what makes `positionKey` the key
    /// macOS actually maintains.
    public static let autosaveName = "TokcatStatusItem"

    /// Where macOS stores the item's spot, derived from the autosave name.
    public static let positionKey = "NSStatusItem Preferred Position \(autosaveName)"

    /// The key AppKit generated for us before the autosave name existed.
    public static let legacyPositionKey = "NSStatusItem Preferred Position Item-0"

    /// The last position Tokcat seated itself; a stored value that differs
    /// from it came from the user.
    public static let seededPositionKey = "TokcatSeededStatusItemPosition"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Copies a pre-autosaveName drag onto the autosave key.
    ///
    /// Must run *before* the first `NSStatusItem` is created: AppKit reads the
    /// preference when it places the item, so a later write would not take
    /// effect until the next launch.
    public func migrateLegacyPositionIfNeeded() {
        guard defaults.object(forKey: Self.positionKey) == nil,
              let legacy = defaults.object(forKey: Self.legacyPositionKey) as? Double
        else { return }
        defaults.set(legacy, forKey: Self.positionKey)
    }

    /// The position macOS currently has on file. Read fresh on every rebuild so
    /// a drag performed between two rebuilds is seen.
    ///
    /// A value that differs from `seededPosition` is by definition the user's,
    /// so it wins over one we wrote — that is what picks the live key when only
    /// one of the two is being maintained.
    public var storedPosition: Double? {
        let candidates = [Self.positionKey, Self.legacyPositionKey]
            .compactMap { defaults.object(forKey: $0) as? Double }
        let seeded = seededPosition
        return candidates.first { $0 != seeded } ?? candidates.first
    }

    public var seededPosition: Double? {
        defaults.object(forKey: Self.seededPositionKey) as? Double
    }

    /// Seats the item at `position` and records it as ours, so the next
    /// decision knows the value is not a user drag.
    public func seat(at position: Double) {
        defaults.set(position, forKey: Self.positionKey)
        defaults.set(position, forKey: Self.legacyPositionKey)
        defaults.set(position, forKey: Self.seededPositionKey)
    }
}
