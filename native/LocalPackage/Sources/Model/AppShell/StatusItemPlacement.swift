import Foundation

// Where a rebuilt status item should sit. Split out of StatusItemController
// (and kept free of AppKit) so the rule has direct test coverage.
//
// macOS stores the item's spot in "NSStatusItem Preferred Position Item-0" —
// the same preference it rewrites when the user Cmd-drags the item. Hidden-item
// recovery used to overwrite that value on every rebuild, which yanked the item
// back out of wherever the user had put it. So: only reseat a value we wrote
// ourselves. If preserving the user's choice didn't bring the item back, the
// stored position is itself the problem and the fallback slot wins.
public enum StatusItemPlacement {
    public struct Decision: Equatable {
        // The position to write, or nil to leave the stored one untouched.
        public let seatAt: Double?
        // Carried back into the next decision.
        public let preservedUserPosition: Bool
    }

    public static func decide(
        stored: Double?,
        seeded: Double?,
        alreadyPreserved: Bool,
        fallback: Double
    ) -> Decision {
        let userMoved = stored != nil && stored != seeded
        if userMoved, !alreadyPreserved {
            return Decision(seatAt: nil, preservedUserPosition: true)
        }
        return Decision(seatAt: fallback, preservedUserPosition: false)
    }
}
