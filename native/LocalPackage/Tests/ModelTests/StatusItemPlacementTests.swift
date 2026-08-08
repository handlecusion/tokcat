import Foundation
import Testing

@testable import Model

// Hidden-item recovery rebuilds the status item, and the rebuild used to
// overwrite "NSStatusItem Preferred Position Item-0" unconditionally — the
// same preference macOS rewrites when the user Cmd-drags the item. The item
// therefore jumped back into the system-item zone every time the user moved
// it. These pin the rule that fixed it.
@Suite struct StatusItemPlacementTests {
    private let fallback = 200.0

    private func decide(
        stored: Double?, seeded: Double?, alreadyPreserved: Bool = false
    ) -> StatusItemPlacement.Decision {
        StatusItemPlacement.decide(
            stored: stored, seeded: seeded,
            alreadyPreserved: alreadyPreserved, fallback: fallback)
    }

    @Test func keepsAPositionTheUserDraggedTo() {
        let d = decide(stored: 500, seeded: fallback)
        #expect(d.seatAt == nil)
        #expect(d.preservedUserPosition)
    }

    @Test func reseatsAPositionWeWroteOurselves() {
        let d = decide(stored: fallback, seeded: fallback)
        #expect(d.seatAt == fallback)
        #expect(!d.preservedUserPosition)
    }

    @Test func seatsWhenNoPositionIsStored() {
        let d = decide(stored: nil, seeded: nil)
        #expect(d.seatAt == fallback)
    }

    // Preserving the user's spot once is a courtesy, not a trap: if the item
    // is still parked on the next pass, that stored position is the problem.
    @Test func fallsBackWhenPreservingDidNotRecoverTheItem() {
        let first = decide(stored: 3000, seeded: fallback)
        #expect(first.seatAt == nil)
        let second = decide(
            stored: 3000, seeded: fallback,
            alreadyPreserved: first.preservedUserPosition)
        #expect(second.seatAt == fallback)
        #expect(!second.preservedUserPosition)
    }
}
