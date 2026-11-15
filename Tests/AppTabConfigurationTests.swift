import Foundation

@main
struct AppTabConfigurationTests {
    static func main() {
        let defaults = AppTabConfiguration()
        precondition(defaults.order == [.input, .keyboard, .tools, .commands, .remote])
        precondition(defaults.visibleTabs == defaults.order)
        precondition(AppTabConfiguration(rawValue: "invalid") == defaults)

        var config = defaults
        config.move(from: IndexSet(integer: 3), to: 0)
        precondition(config.order == [.commands, .input, .keyboard, .tools, .remote])
        precondition(config.resolvedSelection(.keyboard) == .keyboard,
                     "Reordering must preserve page identity")
        precondition(config.toggle(.keyboard))
        precondition(config.visibleTabs == [.commands, .input, .tools, .remote])
        precondition(config.adjacent(to: .commands, direction: 1) == .input)
        precondition(config.adjacent(to: .input, direction: 1) == .tools)
        precondition(config.adjacent(to: .tools, direction: 1) == .remote)
        precondition(config.adjacent(to: .remote, direction: 1) == nil)
        precondition(config.adjacent(to: .commands, direction: -1) == nil)
        precondition(config.resolvedSelection(.keyboard) == .commands)
        precondition(AppTabConfiguration(rawValue: config.rawValue) == config,
                     "Visibility and full ordering must persist")

        precondition(config.toggle(.input))
        precondition(config.toggle(.tools))
        precondition(config.visibleTabs == [.commands, .remote])
        precondition(config.toggle(.remote))
        precondition(config.visibleTabs == [.commands])
        let before = config
        precondition(!config.canToggle(.commands))
        precondition(!config.toggle(.commands) && config == before,
                     "Cannot hide the final active tab")
        precondition(config.canToggle(.input) && config.toggle(.input))
        precondition(config.visibleTabs == [.commands, .input])
        precondition(config.resolvedSelection(.input) == .input)

        // Hiding Input doesn't force an incoming-share selection to a hidden ID.
        precondition(config.toggle(.input))
        precondition(config.resolvedSelection(.input) == .commands)

        let normalized = AppTabConfiguration(rawValue:
            #"{"order":["commands","commands","future","tools"],"hidden":["input","keyboard","tools","commands","future"]}"#)
        // A tab the saved file never mentions is appended, and a saved file
        // hiding every tab it knows cannot hide a tab it does not know.
        precondition(normalized.order == [.commands, .tools, .input, .keyboard, .remote])
        precondition(normalized.visibleTabs == [.remote])
        precondition(AppTabConfiguration(rawValue: #"{"order":[],"hidden":[]}"#) == defaults)

        var multiple = defaults
        // `destination` is an index in the collection *before* removal, so a move
        // of two elements to index 4 inserts after the removal, not at index 4.
        multiple.move(from: IndexSet([0, 2]), to: 4)
        precondition(multiple.order == [.keyboard, .commands, .input, .tools, .remote])
        multiple.move(from: IndexSet(integer: 0), to: 4)
        precondition(multiple.order == [.commands, .input, .tools, .keyboard, .remote])
        let unchanged = multiple
        multiple.move(from: IndexSet(integer: 20), to: 0)
        precondition(multiple == unchanged)
        multiple.move(from: IndexSet(integer: 0), to: 20)
        precondition(multiple == unchanged)
        print("Tab ordering, visibility, selection, persistence and recovery tests passed.")
    }
}
