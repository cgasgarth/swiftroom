import AppKit
import SwiftUI

@MainActor
final class EditorApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var store: EditorStore?
    private var terminationPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        guard sender.keyWindow?.makeFirstResponder(nil) != false else { return .terminateCancel }
        terminationPending = true
        Task {
            await Task.yield()
            let allowed = EditorCloseConfirmation.permitsClosing(store: store, window: sender.keyWindow)
            terminationPending = false
            sender.reply(toApplicationShouldTerminate: allowed)
        }
        return .terminateLater
    }
}

@MainActor
enum EditorCloseConfirmation {
    static func permitsClosing(store: EditorStore?, window: NSWindow?) -> Bool {
        guard let store else { return true }
        guard window?.makeFirstResponder(nil) != false else { return false }
        if store.isUpdatingEdits { return store.prepareToClose(.save) }
        store.endEditing()
        if store.isImporting || store.isExporting { return store.prepareToClose(.save) }
        guard store.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(store.catalogName)?"
        alert.informativeText = "Your photo adjustments and history have unsaved changes."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        let choice: CatalogCloseChoice
        switch alert.runModal() {
        case .alertFirstButtonReturn: choice = .save
        case .alertThirdButtonReturn: choice = .discard
        default: choice = .cancel
        }
        return store.prepareToClose(choice)
    }
}

@MainActor
final class EditorWindowSizing: ObservableObject {
    @Published var minimumContentHeight: CGFloat = 580
}

@MainActor
struct EditorWindowLifecycle: NSViewRepresentable {
    let store: EditorStore?
    let applicationDelegate: EditorApplicationDelegate
    let sizing: EditorWindowSizing

    func makeCoordinator() -> Coordinator { Coordinator(store: store, sizing: sizing) }

    func makeNSView(context: Context) -> WindowProbe {
        applicationDelegate.store = store
        let view = WindowProbe()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: WindowProbe, context: Context) {
        applicationDelegate.store = store
        context.coordinator.store = store
        nsView.coordinator = context.coordinator
        nsView.attach()
    }

    final class WindowProbe: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        override func layout() { super.layout(); coordinator?.scheduleSizing() }
        func attach() { if let window { coordinator?.attach(window) } }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        weak var store: EditorStore?
        weak var previousDelegate: (any NSWindowDelegate)?
        weak var window: NSWindow?
        let sizing: EditorWindowSizing
        private var closePending = false
        private var sizingTask: Task<Void, Never>?

        init(store: EditorStore?, sizing: EditorWindowSizing) { self.store = store; self.sizing = sizing }

        @MainActor
        func attach(_ nextWindow: NSWindow) {
            guard window !== nextWindow else { return }
            window = nextWindow
            previousDelegate = nextWindow.delegate
            nextWindow.delegate = self
            nextWindow.minSize = NSSize(width: 960, height: 640)
            let minimum = nextWindow.contentRect(forFrameRect: CGRect(x: 0, y: 0, width: 960, height: 640)).size
            nextWindow.contentMinSize = minimum
            nextWindow.setFrame(CGRect(origin: nextWindow.frame.origin, size: NSSize(width: 1440, height: 960)),
                                display: false)
            scheduleSizing()
        }

        @MainActor
        func scheduleSizing() {
            guard sizingTask == nil else { return }
            sizingTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                defer { sizingTask = nil }
                guard let window else { return }
                let chrome = window.frame.height - window.contentLayoutRect.height
                let minimum = max(580, 640 - chrome)
                if abs(sizing.minimumContentHeight - minimum) > 0.01 {
                    sizing.minimumContentHeight = minimum
                }
            }
        }

        @MainActor
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard !closePending, sender.makeFirstResponder(nil) else { return false }
            closePending = true
            Task { @MainActor in
                await Task.yield()
                defer { closePending = false }
                guard EditorCloseConfirmation.permitsClosing(store: store, window: sender),
                      previousDelegate?.windowShouldClose?(sender) ?? true else { return }
                sender.close()
            }
            return false
        }

        override nonisolated func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            return previousDelegate?.responds(to: selector) ?? false
        }

        override nonisolated func forwardingTarget(for selector: Selector!) -> Any? {
            previousDelegate
        }
    }
}
