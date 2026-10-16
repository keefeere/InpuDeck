import Foundation

@main
struct CommandUnlockStateTests {
    static func main() {
        var state = CommandUnlockState()
        precondition(!state.isUnlocked)

        let request = state.begin()!
        precondition(state.begin() == nil, "Do not start overlapping Face ID prompts")
        state.becameInactive()
        precondition(state.requestID == request, "System auth may deactivate the scene")
        precondition(!state.authenticated(request, isActive: false))
        precondition(!state.isUnlocked, "Never reveal private UI while inactive")
        precondition(state.becameActive())
        precondition(state.isUnlocked)
        precondition(!state.becameActive(), "Execute a queued action only once")

        state.lock()
        precondition(!state.isUnlocked, "Timeout must lock")
        let cancelled = state.begin()!
        state.lock() // background / tab change / cancel
        precondition(!state.authenticated(cancelled, isActive: true))
        precondition(!state.becameActive())
        precondition(!state.isUnlocked, "Late auth must not unlock after background")

        let newer = state.begin()!
        precondition(!state.authenticated(cancelled, isActive: true))
        precondition(state.requestID == newer, "Old result cannot replace newer auth")
        precondition(state.authenticated(newer, isActive: true))
        state.becameInactive()
        precondition(!state.isUnlocked, "An inactive scene hides an unlocked session")
        precondition(!state.becameActive(), "Returning must not revive an old unlock")
        print("Command unlock lifecycle tests passed.")
    }
}
