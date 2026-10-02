import SwiftUI

private struct AdvancedGroupContext: Equatable {
    let assetID: UUID?
    let catalogID: UUID
    let catalogURL: URL
    let descriptorCount: Int
}

@MainActor
struct AdvancedModuleGroup: View {
    @ObservedObject var store: EditorStore
    let module: ModuleState
    let descriptors: [ProcessingModule]
    @StateObject private var editor: AdvancedModuleEditor
    @State private var expanded: Bool
    @FocusState private var nameFocused: Bool

    init(store: EditorStore, module: ModuleState, descriptors: [ProcessingModule]) {
        self.store = store
        self.module = module
        self.descriptors = descriptors
        _editor = StateObject(wrappedValue: AdvancedModuleEditor(store: store, moduleID: module.id))
        _expanded = State(initialValue: module.enabled)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Enabled", isOn: Binding(get: { editor.draftEnabled }, set: {
                    editor.draftEnabled = $0
                    editor.apply()
                }))
                .toggleStyle(.checkbox).disabled(!editor.canEdit)
                .accessibilityIdentifier("advanced.enabled.\(module.id)")
                if editor.isLoading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading settings…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let schema = editor.schema, editor.hasLoadedValues {
                    AdvancedModuleFields(schema: schema, values: editor.values,
                        onSet: editor.setValue, onValidity: editor.setValidity,
                        onCommit: editor.apply, onEditingChanged: editor.sliderEditingChanged,
                        onSliderSet: editor.setSliderValue)
                        .id(editor.editorRevision).disabled(!editor.canEdit)
                    options
                } else if editor.selectedDescriptor?.hasIntrospection == false {
                    Text("These settings cannot be edited yet. Their current effects are preserved.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = editor.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { editor.activate(descriptors: descriptors) }
                }
            }.padding(.top, 12)
        } label: {
            HStack {
                Text(title).font(.body.weight(.medium))
                Spacer(minLength: 4)
                if !module.enabled { Text("Disabled").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .accessibilityIdentifier("advanced.group.\(module.id)")
        .task(id: AdvancedGroupContext(assetID: store.selectedAssetID, catalogID: store.catalogID,
            catalogURL: store.catalogURL, descriptorCount: descriptors.count)) {
            editor.activate(descriptors: descriptors)
        }
        .onChange(of: store.currentEdits) { _, _ in editor.synchronize() }
        .onDisappear { editor.cancel() }
    }

    private var title: String {
        let raw = descriptors.first { $0.operation == module.operation }?.title ?? module.operation
        let title = raw.prefix(1).uppercased() + raw.dropFirst()
        let count = store.currentEdits.modules.filter { $0.operation == module.operation }.count
        return title + (count > 1 ? " · \(module.instance + 1)" : "")
    }

    private var options: some View {
        DisclosureGroup("Adjustment Options") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Adjustment name", text: Binding(
                    get: { editor.draftName.advancedInstanceLabel }, set: {
                        if $0 != editor.draftName.advancedInstanceLabel { editor.draftName = $0 }
                    }))
                    .textFieldStyle(.roundedBorder).focused($nameFocused)
                    .onSubmit(editor.apply)
                    .onChange(of: nameFocused) { wasFocused, focused in
                        if wasFocused, !focused { editor.apply() }
                    }
                if !editor.nameIsValid {
                    Text("Use at most 127 UTF-8 bytes for the name.").font(.caption).foregroundStyle(.red)
                }
                Button("Reset Parameters") { editor.resetDefaults(); editor.apply() }
                    .disabled(!editor.canEdit || editor.resettableFields.isEmpty)
                DisclosureGroup("Technical Details") {
                    Text("\(module.operation) · Version \(module.version) · Instance \(module.instance + 1)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.padding(.top, 6)
        }
    }
}
