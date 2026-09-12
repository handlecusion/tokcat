import Foundation
import Testing

@testable import Model

// Hidden-item recovery rebuilds the status item, and the rebuild used to
// overwrite the position preference unconditionally — the same preference macOS
// rewrites when the user Cmd-drags the item. The item therefore jumped back
// into the system-item zone every time the user moved it. These pin the rule
// that fixed it, including the follow-up from issue #94: a boolean "we
// preserved once" latch let the *second* rebuild reset a position the user
// still owned, and the visibility watch also fires on display sleep / undock,
// so that second rebuild was usually an unrelated false positive.
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
        #expect(d.seatAt == nil)
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
    }

    // Preserving the user's spot once is a courtesy, not a trap: if the item is
    // still parked on the next pass — i.e. it never came back, so the caller
    // never cleared `preserved` — that stored position is the problem.
    @Test func fallsBackWhenPreservingDidNotRecoverTheItem() {
        let first = decide(stored: 3000, seeded: fallback)
        #expect(first.seatAt == nil)
        let second = decide(
            stored: 3000, seeded: fallback, preserved: first.preserve)
        #expect(second.seatAt == fallback)
        #expect(second.preserve == nil)
    }

    // #94: the item came back after the first rebuild, so StatusItemController
    // cleared `preserved`. A later rebuild — display sleep, undock, anything
    // that trips the hidden heuristic twice — must not spend the user's slot.
    @Test func twoRebuildsDoNotResetAPositionTheUserStillOwns() {
        let first = decide(stored: 500, seeded: fallback)
        #expect(first.seatAt == nil)
        // checkVisibility() saw the item on screen: preserved goes back to nil.
        let second = decide(stored: 500, seeded: fallback, preserved: nil)
        #expect(second.seatAt == nil)
        #expect(second.preserve == 500)
    }

    // #94: a drag between two rebuilds re-arms the preserve branch, because the
    // position now on file is not the one that already had its chance.
    @Test func reArmsPreserveWhenTheUserMovesTheItemAgain() {
        let first = decide(stored: 3000, seeded: fallback)
        #expect(first.preserve == 3000)
        let second = decide(
            stored: 800, seeded: fallback, preserved: first.preserve)
        #expect(second.seatAt == nil)
        #expect(second.preserve == 800)
        // Only that new position, unchanged and still parked, gives up.
        let third = decide(
            stored: 800, seeded: fallback, preserved: second.preserve)
        #expect(third.seatAt == fallback)
    }

    // Dragging back onto the fallback slot is indistinguishable from a value we
    // seated, and stays reseatable — harmless, since reseating it is a no-op.
    @Test func treatsTheSeededValueAsOursEvenWhenPreserved() {
        let d = decide(stored: fallback, seeded: fallback, preserved: fallback)
        #expect(d.seatAt == fallback)
    }
}
