import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let snapFocusedWindow = Self("snapFocusedWindow", default: .init(.space, modifiers: [.control, .option]))
    static let applyLayout = Self("applyLayout", default: .init(.return, modifiers: [.control, .option]))
    static let nextLayout = Self("nextLayout")
}

enum Hotkeys {
    @MainActor
    static func register(model: AppModel) {
        KeyboardShortcuts.onKeyUp(for: .snapFocusedWindow) { [weak model] in model?.snapFocusedWindow() }
        KeyboardShortcuts.onKeyUp(for: .applyLayout) { [weak model] in model?.applyActiveLayout() }
        KeyboardShortcuts.onKeyUp(for: .nextLayout) { [weak model] in
            model?.selectNextLayout()
            model?.applyActiveLayout()
        }
    }
}
