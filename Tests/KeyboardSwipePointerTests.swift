import CoreGraphics
import Foundation

@main
struct KeyboardSwipePointerTests {
    static func main() {
        var moves: [(dx: Int8, dy: Int8)] = []
        let pointer = KeyboardSwipePointer()
        pointer.onPointerMove = { dx, dy in moves.append((dx, dy)) }

        // A stationary touch never becomes a swipe and never moves the pointer.
        pointer.begin(1, at: CGPoint(x: 0, y: 0))
        expect(!pointer.dragged(1, to: CGPoint(x: 0, y: 0)), "A stationary touch is not a drag")
        expect(!pointer.end(1), "A stationary touch ends as a key press")
        expect(moves.isEmpty, "A stationary touch must not move the pointer")
        expect(pointer.canCommitPress(1) == false, "An ended touch cannot commit a press")

        // Movement below the activation threshold stays a key press.
        pointer.begin(2, at: CGPoint(x: 0, y: 0))
        expect(!pointer.dragged(2, to: CGPoint(x: 10, y: 0)), "10 pt is below the 24 pt threshold")
        expect(!pointer.end(2), "A 10 pt drift is not a swipe")

        // Crossing the threshold turns the same touch into pointer control.
        pointer.begin(3, at: CGPoint(x: 0, y: 0))
        expect(pointer.dragged(3, to: CGPoint(x: 24, y: 0)), "24 pt reaches the swipe threshold")
        expect(pointer.isPointerActive, "The keyboard is now in pointer mode")
        expect(deltas(moves) == [36, 0], "24 pt at 1.5 points per step emits one 36 unit report")
        expect(pointer.dragged(3, to: CGPoint(x: 34, y: 0)))
        expect(deltas(moves, from: 1) == [15, 0], "Only the delta since the last report is sent")
        expect(pointer.dragged(3, to: CGPoint(x: 24, y: 0)))
        expect(deltas(moves, from: 2) == [-15, 0], "Backwards movement sends a negative delta")
        expect(pointer.end(3), "The touch ends as a swipe")
        expect(!pointer.isPointerActive, "Ending the touch leaves pointer mode")

        // HID mouse deltas are signed 8-bit, so a long drag is split into reports.
        var steps: [(dx: Int8, dy: Int8)] = []
        let splitter = KeyboardSwipePointer(
            config: KeyboardSwipePointer.Config(movementSensitivity: 1, maximumStep: 50)
        )
        splitter.onPointerMove = { dx, dy in steps.append((dx, dy)) }
        splitter.begin(1, at: CGPoint(x: 0, y: 0))
        _ = splitter.dragged(1, to: CGPoint(x: 120, y: -130))
        expect(flat(steps) == [50, -50, 50, -50, 20, -30], "Every report must fit in Int8")

        // A touch that drifts past the tap tolerance is latched: it can no longer
        // commit a held key-down, so a swipe started after the hold delay cannot
        // type a character the host has already received.
        pointer.begin(4, at: CGPoint(x: 0, y: 0))
        _ = pointer.dragged(4, to: CGPoint(x: 5, y: 0))
        expect(pointer.canCommitPress(4), "5 pt is still a press")
        _ = pointer.dragged(4, to: CGPoint(x: 13, y: 0))
        expect(!pointer.canCommitPress(4), "13 pt latches the touch against a held press")
        // The latch survives the finger settling back inside the tolerance.
        _ = pointer.dragged(4, to: CGPoint(x: 2, y: 0))
        expect(!pointer.canCommitPress(4), "The latch is not cleared by drifting back")
        expect(!pointer.end(4), "The touch still ends as a key press, sent on lift")

        // Each finger keeps its own anchor and emitted position.
        var fingerMoves: [(dx: Int8, dy: Int8)] = []
        let fingers = KeyboardSwipePointer()
        fingers.onPointerMove = { dx, dy in fingerMoves.append((dx, dy)) }
        fingers.begin(5, at: CGPoint(x: 0, y: 0))
        fingers.begin(6, at: CGPoint(x: 200, y: 0))
        _ = fingers.dragged(5, to: CGPoint(x: 24, y: 0))
        _ = fingers.dragged(6, to: CGPoint(x: 224, y: 0))
        expect(flat(fingerMoves) == [36, 0, 36, 0], "Independent fingers each emit their own movement")
        _ = fingers.end(5)
        _ = fingers.end(6)

        // Switching destinations or layouts must forget in-flight touches.
        pointer.begin(7, at: CGPoint(x: 0, y: 0))
        _ = pointer.dragged(7, to: CGPoint(x: 40, y: 0))
        pointer.reset()
        expect(!pointer.end(7), "Reset forgets the previous touch")
        expect(!pointer.isPointerActive, "Reset leaves no active swipe")

        // Postponed key-downs must reach the host in the order the fingers
        // reached their keys, otherwise a fast Enter overtakes the letter that
        // is still inside its hold window.
        var order: [String] = []
        let ordered = KeyboardSwipePointer()
        ordered.deferPress("a", startedAt: 0) { order.append("a") }
        ordered.deferPress("b", startedAt: 5) { order.append("b") }
        ordered.flushDeferredPresses(before: 3)
        expect(order == ["a"], "only keys touched by that moment are drained")
        ordered.flushDeferredPresses(before: 100)
        expect(order == ["a", "b"], "the rest drains oldest first")
        ordered.deferPress("c", startedAt: 10) { order.append("c") }
        ordered.cancelDeferredPress("c")
        ordered.flushDeferredPresses(before: 100)
        expect(order == ["a", "b"], "a cancelled key never reaches the host")

        // A drained key-down runs the normal press path, which may try to drain
        // again; entries leave the queue before running, so nothing runs twice.
        var reentrant: [String] = []
        let nested = KeyboardSwipePointer()
        nested.deferPress("x", startedAt: 0) {
            reentrant.append("x")
            nested.flushDeferredPresses(before: 100)
        }
        nested.deferPress("y", startedAt: 1) { reentrant.append("y") }
        nested.flushDeferredPresses(before: 100)
        expect(reentrant == ["x", "y"], "a commit cannot drain the same queue twice")

        // Reset must forget postponed key-downs along with the touches.
        let dropped = KeyboardSwipePointer()
        var droppedOrder: [String] = []
        dropped.deferPress("z", startedAt: 0) { droppedOrder.append("z") }
        dropped.reset()
        dropped.flushDeferredPresses(before: 100)
        expect(droppedOrder.isEmpty, "reset drops a postponed key-down")

        // A reset that lands while a finger is still down also forgets the touch
        // itself, so `end` can no longer report that it was a pointer swipe. The
        // key button must therefore keep its own latch: trusting this answer
        // alone would let an in-flight swipe type a character on lift.
        let forgot = KeyboardSwipePointer()
        forgot.begin("swipe", at: .zero)
        expect(forgot.dragged("swipe", to: CGPoint(x: 120, y: 0)), "the drag becomes a swipe")
        forgot.reset()
        expect(!forgot.end("swipe"), "a reset touch is not reported as a swipe any more")

        print("PASS: keyboard swipe separates taps from pointer drags and splits HID deltas")
    }

    private static func expect(_ condition: Bool, _ message: String = "") {
        precondition(condition, "keyboard swipe test failed: \(message)")
    }

    private static func deltas(
        _ moves: [(dx: Int8, dy: Int8)],
        from index: Int = 0
    ) -> [Int] {
        guard index < moves.count else { return [] }
        return [Int(moves[index].dx), Int(moves[index].dy)]
    }

    private static func flat(_ moves: [(dx: Int8, dy: Int8)]) -> [Int] {
        moves.flatMap { [Int($0.dx), Int($0.dy)] }
    }
}
