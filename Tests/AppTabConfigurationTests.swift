import Foundation

@main
struct AppTabConfigurationTests {
    static func main() {
        let defaults = AppTabConfiguration()
        precondition(defaults.order == [.input, .keyboard, .tools, .commands])
        precondition(defaults.visibleTabs == defaults.order)
        precondition(AppTabConfiguration(rawValue: "invalid") == defaults)

        var config = defaults
        config.move(from: IndexSet(integer: 3), to: 0)
        precondition(config.order == [.commands, .input, .keyboard, .tools])
        precondition(config.resolvedSelection(.keyboard) == .keyboard,
                     "Reordering must preserve page identity")
        precondition(config.toggle(.keyboard))
        precondition(config.visibleTabs == [.commands, .input, .tools])
        precondition(config.adjacent(to: .commands, direction: 1) == .input)
        precondition(config.adjacent(to: .input, direction: 1) == .tools)
        precondition(config.adjacent(to: .tools, direction: 1) == nil)
        precondition(config.adjacent(to: .commands, direction: -1) == nil)
        precondition(config.resolvedSelection(.keyboard) == .commands)
        precondition(AppTabConfiguration(rawValue: config.rawValue) == config,
                     "Visibility and full ordering must persist")

        precondition(config.toggle(.input))
        precondition(config.toggle(.tools))
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
        precondition(normalized.order == [.commands, .tools, .input, .keyboard])
        precondition(normalized.visibleTabs == [.commands])
        precondition(AppTabConfiguration(rawValue: #"{"order":[],"hidden":[]}"#) == defaults)

        var multiple = defaults
        multiple.move(from: IndexSet([0, 2]), to: 4)
        precondition(multiple.order == [.keyboard, .commands, .input, .tools])
        multiple.move(from: IndexSet(integer: 0), to: 4)
        precondition(multiple.order == [.commands, .input, .tools, .keyboard])
        let unchanged = multiple
        multiple.move(from: IndexSet(integer: 20), to: 0)
        precondition(multiple == unchanged)
        multiple.move(from: IndexSet(integer: 0), to: 20)
        precondition(multiple == unchanged)
        print("Tab ordering, visibility, selection, persistence and recovery tests passed.")
    }
}
