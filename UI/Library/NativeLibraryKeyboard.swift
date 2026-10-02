import SwiftUI

@MainActor
struct NativeLibraryKeyboard: ViewModifier {
    @ObservedObject var model: LibraryController

    func body(content: Content) -> some View {
        content.onKeyPress(phases: .down, action: handle)
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .escape { model.clearSelection(); return .handled }
        if press.modifiers == .command, press.characters.lowercased() == "a" {
            model.selectAll(); return .handled
        }
        guard press.modifiers.isEmpty, !model.selectedIDs.isEmpty else { return .ignored }
        if let rating = Int(press.characters), (0...5).contains(rating) {
            model.setRating(rating); return .handled
        }
        switch press.characters.lowercased() {
        case "f": model.toggleFavorites(); return .handled
        case "x": model.toggleRejected(); return .handled
        default: return .ignored
        }
    }
}
