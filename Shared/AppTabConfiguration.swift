import Foundation

enum AppTab: String, Codable, CaseIterable, Identifiable, Sendable {
    case input, keyboard, tools, commands
    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .input: "Ввід"
        case .keyboard: "Клавіатура"
        case .tools: "Інструменти"
        case .commands: "Команди"
        }
    }

    var systemImage: String {
        switch self {
        case .input, .keyboard: "keyboard"
        case .tools: "switch.2"
        case .commands: "command.square"
        }
    }

    var assetName: String? { self == .input ? "InputTabIcon" : nil }
}

/// Stable identities, not visible indices. Unknown/duplicate saved IDs are
/// ignored, new tabs are appended, and at least one tab always remains visible.
struct AppTabConfiguration: Equatable {
    private(set) var order: [AppTab]
    private(set) var hidden: Set<AppTab>

    private struct Saved: Codable {
        var order: [String]
        var hidden: [String]
    }

    init(rawValue: String = "") {
        let saved = rawValue.data(using: .utf8).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        var seen = Set<AppTab>()
        order = (saved?.order ?? []).compactMap(AppTab.init(rawValue:)).filter { seen.insert($0).inserted }
        order += AppTab.allCases.filter { !seen.contains($0) }
        hidden = Set((saved?.hidden ?? []).compactMap(AppTab.init(rawValue:)))
        if hidden.count == AppTab.allCases.count { hidden.remove(order[0]) }
    }

    var visibleTabs: [AppTab] { order.filter { !hidden.contains($0) } }
    func isEnabled(_ tab: AppTab) -> Bool { !hidden.contains(tab) }
    func canToggle(_ tab: AppTab) -> Bool { hidden.contains(tab) || visibleTabs.count > 1 }

    @discardableResult
    mutating func toggle(_ tab: AppTab) -> Bool {
        guard canToggle(tab) else { return false }
        if hidden.contains(tab) { hidden.remove(tab) } else { hidden.insert(tab) }
        return true
    }

    mutating func move(from source: IndexSet, to destination: Int) {
        guard destination >= 0, destination <= order.count,
              source.allSatisfy({ order.indices.contains($0) }) else { return }
        let moving = source.sorted().map { order[$0] }
        let insertion = destination - source.filter { $0 < destination }.count
        order = order.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        order.insert(contentsOf: moving, at: insertion)
    }

    func resolvedSelection(_ requested: AppTab) -> AppTab {
        isEnabled(requested) ? requested : visibleTabs[0]
    }

    func adjacent(to selected: AppTab, direction: Int) -> AppTab? {
        let visible = visibleTabs
        guard let index = visible.firstIndex(of: resolvedSelection(selected)) else { return nil }
        let next = index + direction
        return visible.indices.contains(next) ? visible[next] : nil
    }

    var rawValue: String {
        let saved = Saved(order: order.map(\.rawValue), hidden: order.filter { hidden.contains($0) }.map(\.rawValue))
        guard let data = try? JSONEncoder().encode(saved) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
