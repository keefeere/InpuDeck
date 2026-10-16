import Foundation

/// Lifecycle bookkeeping independent of LocalAuthentication and SwiftUI.
/// An authentication sheet may make the scene inactive. Its result must wait
/// for foreground activation, and results from cancelled requests are ignored.
struct CommandUnlockState {
    private(set) var isUnlocked = false
    private(set) var requestID: UUID?
    private var awaitsActivation = false

    /// Queue acceptance is permitted only in an authenticated foreground tab.
    func canSendCommands(isForegroundActive: Bool, isActiveTab: Bool) -> Bool {
        isUnlocked && isForegroundActive && isActiveTab
    }

    mutating func begin() -> UUID? {
        guard requestID == nil else { return nil }
        let id = UUID()
        requestID = id
        awaitsActivation = false
        return id
    }

    mutating func authenticated(_ id: UUID, isActive: Bool) -> Bool {
        guard requestID == id else { return false }
        awaitsActivation = true
        return isActive ? becameActive() : false
    }

    mutating func becameActive() -> Bool {
        guard requestID != nil, awaitsActivation else { return false }
        requestID = nil
        awaitsActivation = false
        isUnlocked = true
        return true
    }

    mutating func becameInactive() {
        isUnlocked = false
    }

    mutating func lock() {
        isUnlocked = false
        requestID = nil
        awaitsActivation = false
    }
}
