import SwiftUI

struct LibraryCollectionDraft: Identifiable {
    let id = UUID()
    var collectionID: UUID?
    var name = ""

    init(collection: PhotoCollection? = nil) {
        collectionID = collection?.id
        name = collection?.name ?? ""
    }
}

@MainActor
struct LibraryCollectionEditor: View {
    @ObservedObject var model: LibraryController
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var includesSelection = true
    @FocusState private var nameIsFocused: Bool
    let draft: LibraryCollectionDraft

    init(model: LibraryController, draft: LibraryCollectionDraft) {
        self.model = model
        self.draft = draft
        _name = State(initialValue: draft.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.collectionID == nil ? "New Collection" : "Rename Collection").font(.headline)
            TextField("Collection name", text: $name).textFieldStyle(.roundedBorder)
                .focused($nameIsFocused).accessibilityIdentifier("library.collectionName")
            if draft.collectionID == nil {
                Toggle("Add \(model.selectedIDs.count) selected photos", isOn: $includesSelection)
                    .disabled(model.selectedIDs.isEmpty)
            }
            if !name.isEmpty, !nameAvailable {
                Text("Choose a unique, nonempty collection name.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(draft.collectionID == nil ? "Create" : "Rename", action: save)
                    .keyboardShortcut(.defaultAction).disabled(!nameAvailable)
                    .accessibilityIdentifier("library.collectionSave")
            }
        }.padding(24).frame(width: 360).onAppear { nameIsFocused = true }
    }

    private var nameAvailable: Bool {
        model.store.library.collectionNameAvailable(name, excluding: draft.collectionID)
    }

    private func save() {
        if let id = draft.collectionID {
            guard model.renameCollection(id, name: name) else { return }
        } else {
            guard model.createCollection(name: name, addingSelection: includesSelection) != nil else { return }
        }
        dismiss()
    }
}
