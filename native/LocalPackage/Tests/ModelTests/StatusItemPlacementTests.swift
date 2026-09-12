import Foundation
import Testing

@testable import Model

// Hidden-item recovery rebuilds the status item, and the rebuild used to
// overwrite the position preference unconditionally — the same preference macOS
// rewrites when the user Cmd-drags the item. The item therefore jumped back
// into the system-item zone every time the user moved it (issue #94).
//
// The rule that fixed it has two halves, and on-device measurement showed both
// are needed. A boolean "we preserved once" latch let the *second* rebuild
// reset a position the user still owned, so the decision carries *which*
// position it spared. And preserving by writing nothing leaves the rebuilt item
// with no position at all — removing a status item clears its saved position —
// so preserving means seating that exact value again.
@Suite struct StatusItemPlacementTests {
    private let fallback = 200.0

    private func decide(
        stored: Double?, seeded: Double?, preserved: Double? = nil
    ) -> StatusItemPlacement.Decision {
        StatusItemPlacement.decide(
            stored: stored, seeded: seeded,
            preserved: preserved, fallback: fallback)
    }

    @Test func keepsAPositionTheUserDraggedTo() {
        let d = decide(stored: 500, seeded: fallback)
        #expect(d.seatAt == 500)
        #expect(d.preserve == 500)
    }

    @Test func reseatsAPositionWeWroteOurselves() {
        let d = decide(stored: fallback, seeded: fallback)
        #expect(d.seatAt == fallback)
        #expect(d.preserve == nil)
    }

    @Test func seatsWhenNoPositionIsStored() {
        let d = decide(stored: nil, seeded: nil)
        #expect(d.seatAt == fallback)
        #expect(d.preserve == nil)
    }

    // Preserving the user's spot once is a courtesy, not a trap: if the item is
    // still parked on the next pass — i.e. it never came back, so the caller
    // never cleared `preserved` — that stored position is the problem.
    @Test func fallsBackWhenPreservingDidNotRecoverTheItem() {
        let first = decide(stored: 3000, seeded: fallback)
        #expect(first.seatAt == 3000)
        let second = decide(
            stored: 3000, seeded: fallback, preserved: first.preserve)
        #expect(second.seatAt == fallback)
        #expect(second.preserve == nil)
    }

    // #94: the item came back after the first rebuild, so StatusItemController
    // cleared `preserved`. A later rebuild — undock, any relayout that trips
    // the hidden heuristic twice — must not spend the user's slot. Writing the
    // position back on every one of those rebuilds is what keeps the slot,
    // since the removal clears it each time.
    @Test func twoRebuildsDoNotResetAPositionTheUserStillOwns() {
        let first = decide(stored: 500, seeded: fallback)
        #expect(first.seatAt == 500)
        // checkVisibility() saw the item on screen: preserved goes back to nil.
        let second = decide(stored: 500, seeded: fallback, preserved: nil)
        #expect(second.seatAt == 500)
        #expect(second.preserve == 500)
    }

    // #94: a drag between two rebuilds re-arms the preserve branch, because the
    // position now on file is not the one that already had its chance.
    @Test func reArmsPreserveWhenTheUserMovesTheItemAgain() {
        let first = decide(stored: 3000, seeded: fallback)
        #expect(first.preserve == 3000)
        let second = decide(
            stored: 800, seeded: fallback, preserved: first.preserve)
        #expect(second.seatAt == 800)
        #expect(second.preserve == 800)
        // Only that new position, unchanged and still parked, gives up.
        let third = decide(
            stored: 800, seeded: fallback, preserved: second.preserve)
        #expect(third.seatAt == fallback)
        #expect(third.preserve == nil)
    }

    // Dragging back onto the fallback slot is indistinguishable from a value we
    // seated, and stays reseatable — harmless, since reseating it is a no-op.
    @Test func treatsTheSeededValueAsOursEvenWhenPreserved() {
        let d = decide(stored: fallback, seeded: fallback, preserved: fallback)
        #expect(d.seatAt == fallback)
    }

    // The decision never invents a slot: whatever it seats is either the
    // position on file or our fallback, so a rebuild cannot move the item
    // somewhere neither the user nor Tokcat chose.
    @Test func onlyEverSeatsTheStoredPositionOrTheFallback() {
        let positions: [Double?] = [nil, 0, fallback, 500, 3000, -80]
        for stored in positions {
            for seeded in positions {
                for preserved in positions {
                    let d = decide(
                        stored: stored, seeded: seeded, preserved: preserved)
                    #expect(Optional(d.seatAt) == stored || d.seatAt == fallback)
                }
            }
        }
    }

    // `seatsOurOwnValue` is what tells StatusItemController whether to stamp the
    // seeded marker. Getting it backwards on a preserved position would make the
    // next rebuild read that position as ours and seat the fallback over it —
    // #94, one rebuild later — so pin it to the two cases directly.
    @Test func claimsOnlyTheFallbackAsOurs() {
        #expect(decide(stored: 500, seeded: fallback).seatsOurOwnValue == false)
        #expect(decide(stored: nil, seeded: nil).seatsOurOwnValue)
        #expect(decide(stored: fallback, seeded: fallback).seatsOurOwnValue)
        #expect(decide(stored: 3000, seeded: fallback, preserved: 3000)
            .seatsOurOwnValue)
    }
}
