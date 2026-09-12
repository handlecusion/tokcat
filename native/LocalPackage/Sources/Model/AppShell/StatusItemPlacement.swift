import Foundation

// Where a rebuilt status item should sit. Split out of StatusItemController
// (and kept free of AppKit) so the rule has direct test coverage.
//
// macOS stores the item's spot in "NSStatusItem Preferred Position <name>" —
// the same preference it rewrites when the user Cmd-drags the item (see
// StatusItemPositionStore).
//
// The rebuild ALWAYS writes that preference, because the removal that starts
// the rebuild clears it: measured on macOS 26, NSStatusBar.removeStatusItem()
// leaves the item's saved position gone from the store. A rebuild that
// "preserves" a position by writing nothing therefore hands the new item no
// position at all, and the bar parks it off-screen until a later rebuild
// seats something. So preserving the user's slot means seating that exact
// value again, which is also what repopulates the key for the next launch.
//
// The one exception is a stored position that is itself the reason the item is
// parked. That is only established when the *same* user position has already
// had a rebuild to itself and the item never came back on screen since — which
// is what `preserved` carries. A latching "we preserved once" flag was not
// enough: the visibility watch also fires on unrelated relayouts, so the second
// rebuild it saw was usually a false positive, and it reset a position the user
// still owned.
public enum StatusItemPlacement {
    public struct Decision: Equatable {
        // The position to write. Always written — see above.
        public let seatAt: Double
        // The user position this rebuild is giving a chance, carried into the
        // next decision. nil once the position has been overruled (we seated
        // the fallback); the caller also clears it as soon as the item is seen
        // on screen, which vindicates the position.
        public let preserve: Double?

        // Whether `seatAt` is a value Tokcat picked rather than the user's own
        // position being written back after the removal cleared it.
        //
        // Only our own value may be recorded in the seeded marker. Stamping a
        // preserved user position as ours would make the *next* rebuild read it
        // back as Tokcat's and drop the fallback on top of it — issue #94
        // again, one rebuild later.
        public var seatsOurOwnValue: Bool { preserve == nil }
    }

    public static func decide(
        stored: Double?,
        seeded: Double?,
        preserved: Double?,
        fallback: Double
    ) -> Decision {
        guard let stored, stored != seeded else {
            // Nothing stored, or the value is one we seated ourselves:
            // reseating the fallback costs the user nothing.
            return Decision(seatAt: fallback, preserve: nil)
        }
        if preserved == stored {
            // This exact position already had a rebuild to itself and the item
            // is parked again without ever having come back: the position is
            // the problem, so the fallback slot wins.
            return Decision(seatAt: fallback, preserve: nil)
        }
        // First rebuild for this position, or the user has dragged since the
        // last one. Seat it again — that is what makes the rebuilt item
        // reappear in the same slot instead of off-screen.
        return Decision(seatAt: stored, preserve: stored)
    }
}
