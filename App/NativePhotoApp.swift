import AppKit
import SwiftUI

@MainActor
final class ApplicationState: ObservableObject {
    let store: EditorStore?
    let failure: String?
    let importURLs: [URL]

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let root = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        var catalogURL = root.appendingPathComponent("TestCatalog", isDirectory: true)
        var inputs: [URL] = []
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--appearance", index + 1 < arguments.count {
                index += 1
                let name: NSAppearance.Name = arguments[index] == "dark" ? .darkAqua : .aqua
                NSApplication.shared.appearance = NSAppearance(named: name)
            } else if argument == "--catalog" || argument == "--import", index + 1 < arguments.count {
                index += 1
                let url = URL(fileURLWithPath: arguments[index])
                if argument == "--catalog" { catalogURL = url } else { inputs.append(url) }
            }
            index += 1
        }
        importURLs = inputs
        do {
            let engine = NativePhotoEngineFactory.make(cacheDirectory: catalogURL.appendingPathComponent("Cache"))
            store = try EditorStore(engine: engine, catalogURL: catalogURL)
            failure = nil
        } catch {
            store = nil
            failure = error.localizedDescription
        }
    }
}

@main
struct NativePhotoApp: App {
    @StateObject private var application = ApplicationState()

    var body: some Scene {
        Window("swiftroom", id: "editor") {
            Group {
                if let store = application.store {
                    NativePhotoRootView(store: store)
                        .task {
                            store.start()
                            if !application.importURLs.isEmpty { await store.importURLs(application.importURLs) }
                        }
                } else {
                    ContentUnavailableView {
                        Label("swiftroom could not start", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(application.failure ?? "The photo engine is unavailable.")
                            .textSelection(.enabled)
                    } actions: {
                        Button("Quit swiftroom") { NSApp.terminate(nil) }
                    }
                    .padding(40)
                }
            }
            .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1440, height: 960)
        .commands { EditorCommands(store: application.store) }
    }
}

struct EditorCommands: Commands {
    let store: EditorStore?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import Photos…") { store?.importPhotos() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Open Catalog…") { store?.openCatalogPanel() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(store?.isImporting ?? false)
            Divider()
            Button("Save Catalog") { store?.save() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Export Photo…") { store?.exportPhoto() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(store?.selectedDocument == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { store?.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!(store?.canUndo ?? false))
            Button("Redo") { store?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!(store?.canRedo ?? false))
        }
        CommandMenu("Photo") {
            Button("Previous Photo") { store?.selectNextPhoto(-1) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Next Photo") { store?.selectNextPhoto(1) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Fit to View") { store?.zoomToFit() }
                .keyboardShortcut("0", modifiers: .command)
            Button("Actual Pixels") { store?.zoomToActualSize() }
                .keyboardShortcut("1", modifiers: .command)
            Divider()
            Button("Reset Adjustments") { store?.resetEdits() }
                .disabled(store?.selectedDocument == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Inspector") { store?.isInspectorVisible.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Toggle Library") { store?.isLibraryVisible.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .option])
        }
    }
}
