import Foundation

@main
struct KeyboardSwipePointerTests {
    static func main() {
        var moves: [(Int8, Int8)] = []
        let pointer = KeyboardSwipePointer()
        pointer.onPointerMove = { dx, dy in moves.append((dx, dy)) }

        // A stationary touch never becomes a swipe and never moves the pointer.
        pointer.begin(1, at: CGPoint(x: 0, y: 0))
        precondition(!pointer.dragged(1, to: CGPoint(x: 0, y: 0)), "A stationary touch is not a drag")
        precondition(!pointer.end(1), "A stationary touch ends as a key press")
        precondition(moves.isEmpty, "A stationary touch must not move the pointer")
        precondition(!pointer.looksLikeDrag(1), "No movement is still a press")

        // Movement below the activation threshold stays a key press.
        pointer.begin(2, at: CGPoint(x: 0, y: 0))
        precondition(!pointer.dragged(2, to: CGPoint(x: 10, y: 0)), "10 pt is below the 24 pt threshold")
        precondition(!pointer.end(2), "A 10 pt drift is not a swipe")

        // Crossing the threshold turns the same touch into pointer control.
        pointer.begin(3, at: CGPoint(x: 0, y: 0))
        precondition(pointer.dragged(3, to: CGPoint(x: 24, y: 0)), "24 pt reaches the swipe threshold")
        precondition(pointer.isPointerActive, "The keyboard is now in pointer mode")
        precondition(moves == [(36, 0)], "24 pt at 1.5 points per step emits one 36 unit report")
        precondition(pointer.dragged(3, to: CGPoint(x: 34, y: 0)))
        precondition(moves.count == 2 && moves[1] == (15, 0), "Only the delta since the last report is sent")
        precondition(pointer.dragged(3, to: CGPoint(x: 24, y: 0)))
        precondition(moves.count == 3 && moves[2] == (-15, 0), "Backwards movement sends a negative delta")
        precondition(pointer.end(3), "The touch ends as a swipe")
        precondition(!pointer.isPointerActive, "Ending the touch leaves pointer mode")

        // HID mouse deltas are signed 8-bit, so a long drag is split into reports.
        var steps: [(Int8, Int8)] = []
        let splitter = KeyboardSwipePointer(Config(movementSensitivity: 1, maximumStep: 50))
        splitter.onPointerMove = { dx, dy in steps.append((dx, dy)) }
        splitter.begin(1, at: CGPoint(x: 0, y: 0))
        splitter.dragged(1, to: CGPoint(x: 120, y: -130))
        precondition(steps == [(50, -50), (50, -50), (20, -30)], "Every report must fit in Int8")

        // A touch that drifts past the tap tolerance postpones the key-down so a
        // swipe starting on the key never types a character.
        pointer.begin(4, at: CGPoint(x: 0, y: 0))
        pointer.dragged(4, to: CGPoint(x: 5, y: 0))
        precondition(!pointer.looksLikeDrag(4), "5 pt is still a press")
        pointer.dragged(4, to: CGPoint(x: 13, y: 0))
        precondition(pointer.looksLikeDrag(4), "13 pt postpones the key-down")
        pointer.end(4)

        // Switching destinations or layouts must forget in-flight touches.
        pointer.begin(5, at: CGPoint(x: 0, y: 0))
        pointer.dragged(5, to: CGPoint(x: 40, y: 0))
        pointer.reset()
        precondition(!pointer.end(5), "Reset forgets the previous touch")
        precondition(!pointer.isPointerActive, "Reset leaves no active swipe")

        print("PASS: keyboard swipe separates taps from pointer drags and splits HID deltas")
    }
}
