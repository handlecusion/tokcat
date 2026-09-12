import Foundation

// Where a rebuilt status item should sit. Split out of StatusItemController
// (and kept free of AppKit) so the rule has direct test coverage.
//
// macOS stores the item's spot in "NSStatusItem Preferred Position <name>" —
// the same preference it rewrites when the user Cmd-drags the item (see
// StatusItemPositionStore). Hidden-item recovery used to overwrite that value
// on every rebuild, which yanked the item back out of wherever the user had put
// it. So: only reseat a value we wrote ourselves.
//
// The one exception is a stored position that is itself the reason the item is
// parked. That is only established when the *same* user position has already
// had a rebuild to itself and the item never came back on screen since — which
// is what `preserved` carries. A latching "we preserved once" flag was not
// enough: the visibility watch also fires on display sleep and undock, so the
// second rebuild it saw was usually an unrelated false positive, and it reset a
// position the user still owned.
public enum StatusItemPlacement {
    public struct Decision: Equatable {
        // The position to write, or nil to leave the stored one untouched.
        public let seatAt: Double?
        // The user position this rebuild is giving a chance, carried into the
        // next decision. nil once the position has been overruled (we seated
        // the fallback); the caller also clears it as soon as the item is seen
        // on screen, which vindicates the position.
        public let preserve: Double?
    }

    public static func decide(
        stored: Double?,
        seeded: Double?,
        preserved: Double?,
        fallback: Double
    ) -> Decision {
        guard let stored, stored != seeded else {
            // Nothing stored, or the value is one we seated ourselves:
            // reseating it costs the user nothing.
            return Decision(seatAt: fallback, preserve: nil)
        }
        if preserved == stored {
            // This exact position already had a rebuild to itself and the item
            // is parked again without ever having come back: the position is
            // the problem, so the fallback slot wins.
            return Decision(seatAt: fallback, preserve: nil)
        }
        // First rebuild for this position, or the user has dragged since the
        // last one — give their choice a chance.
        return Decision(seatAt: nil, preserve: stored)
    }
}
