import SwiftUI

private struct AdvancedDocumentIdentity: Equatable {
    let assetID: UUID?
    let catalogID: UUID
    let catalogURL: URL
}

@MainActor
struct AdvancedModuleInspector: View {
    @ObservedObject var store: EditorStore
    @StateObject private var editor: AdvancedModuleEditor
    @State private var search = ""
    @State private var showsAllOperations = false

    init(store: EditorStore) {
        self.store = store
        _editor = StateObject(wrappedValue: AdvancedModuleEditor(store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            operationBrowser
            if editor.isLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading module parameters…").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error = editor.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Button(editor.selectedOperation.isEmpty ? "Reload Operations" : "Reload Parameters") {
                        if editor.selectedOperation.isEmpty { editor.activate() } else {
                            editor.chooseOperation(editor.selectedOperation)
                        }
                    }
                        .disabled(editor.isApplying)
                }
                .accessibilityIdentifier("advanced.error")
            }
            if !editor.selectedOperation.isEmpty {
                moduleIdentity
                moduleContent
                supportNotice
            }
            if let status = editor.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("advanced.status")
            }
        }
        .accessibilityIdentifier("advanced.inspector")
        .task(id: AdvancedDocumentIdentity(assetID: store.selectedAssetID, catalogID: store.catalogID,
            catalogURL: store.catalogURL)) {
            editor.activate()
        }
        .onChange(of: store.currentEdits) { _, _ in editor.synchronize() }
        .onDisappear { editor.cancel() }
    }

    private var operationBrowser: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search operations", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("advanced.search")
            Toggle("Show all engine operations", isOn: $showsAllOperations)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("advanced.allOperations")
            if filteredOperations.isEmpty {
                Text(
                    search.isEmpty ? "No retained modules in this photo." : "No operations match this search."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            Picker(
                "Operation",
                selection: Binding(get: { editor.selectedOperation }, set: editor.chooseOperation)
            ) {
                if editor.selectedOperation.isEmpty { Text("Choose an operation").tag("") }
                ForEach(filteredOperations) { operation in
                    Text(
                        operation.title + (operation.instanceCount > 0 ? " (\(operation.instanceCount))" : "")
                    )
                    .tag(operation.operation)
                }
                if !filteredOperations.contains(where: { $0.operation == editor.selectedOperation }),
                    let current = editor.operations.first(where: { $0.operation == editor.selectedOperation }) {
                    Text("Current: \(current.title)").tag(current.operation)
                }
            }
            .pickerStyle(.menu)
            .disabled(editor.isApplying || editor.operations.isEmpty)
            .accessibilityIdentifier("advanced.operation")
            Text(
                "\(filteredOperations.count) operations · \(editor.instances.count) instances of this operation"
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var filteredOperations: [AdvancedOperation] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return editor.operations.filter { operation in
            (showsAllOperations || operation.instanceCount > 0)
                && (query.isEmpty || operation.title.localizedStandardContains(query)
                    || operation.operation.localizedStandardContains(query))
        }
    }

    private var moduleIdentity: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(editor.selectedDescriptor?.title ?? editor.selectedOperation).font(.headline)
            Text(editor.selectedOperation).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if !editor.instances.isEmpty {
                Picker(
                    "Instance",
                    selection: Binding(
                        get: { editor.selectedModuleID },
                        set: { id in
                            if let id { editor.chooseInstance(id) }
                        })
                ) {
                    ForEach(editor.instances) { module in
                        Text(instanceTitle(module)).tag(Optional(module.id))
                    }
                }
                .pickerStyle(.menu).disabled(editor.isApplying)
                .accessibilityIdentifier("advanced.instance")
                if let module = editor.instances.first(where: { $0.id == editor.selectedModuleID }) {
                    Text("Version \(module.version) · Instance \(module.instance + 1)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var moduleContent: some View {
        if editor.instances.isEmpty {
            Text("This operation has no instance in the photo. Adding modules is not yet available.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let schema = editor.schema { availableSchema(schema) }
        } else if editor.selectedDescriptor?.hasIntrospection == false {
            Text("This operation does not expose a parameter schema. Its complete state is retained.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if let schema = editor.schema, editor.hasLoadedValues, !editor.isLoading {
            VStack(alignment: .leading, spacing: 18) {
                Toggle("Module enabled", isOn: $editor.draftEnabled)
                    .toggleStyle(.checkbox).disabled(!editor.canEdit)
                    .accessibilityIdentifier("advanced.enabled")
                TextField("Instance label", text: $editor.draftName)
                    .textFieldStyle(.roundedBorder).disabled(!editor.canEdit)
                    .accessibilityIdentifier("advanced.name")
                if !editor.nameIsValid {
                    Text("Instance labels may contain at most 127 UTF-8 bytes.")
                        .font(.caption).foregroundStyle(.red)
                }
                if schema.fields.isEmpty {
                    Text("No scalar parameters are exposed for this operation.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    AdvancedModuleFields(
                        schema: schema, values: editor.values,
                        onSet: editor.setValue, onValidity: editor.setValidity
                    )
                    .id(editor.editorRevision).disabled(!editor.canEdit)
                }
                draftActions
            }
        }
    }

    private var draftActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Reset to Schema Defaults", action: editor.resetDefaults)
                .disabled(!editor.canEdit || editor.resettableFields.isEmpty)
                .accessibilityIdentifier("advanced.resetAll")
            HStack {
                Button("Discard", action: editor.discard)
                    .disabled(!editor.canEdit || (!editor.hasChanges && editor.invalidFields.isEmpty))
                    .accessibilityIdentifier("advanced.discard")
                Spacer()
                if editor.isApplying { ProgressView().controlSize(.small) }
                Button("Apply", action: editor.apply)
                    .buttonStyle(.borderedProminent).disabled(!editor.canApply)
                    .accessibilityIdentifier("advanced.apply")
            }
            Text(
                editor.invalidFields.isEmpty && editor.nameIsValid
                    ? "Apply records one undoable adjustment." : "Correct invalid values before applying."
            )
            .font(.caption).foregroundStyle(.secondary)
            if editor.hasChanges {
                Text("Unapplied draft. Apply before switching modules.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var supportNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Values use the engine's native units; unit labels are unavailable.")
            Text(
                "Curve points, masks, blending and new instances do not have native controls yet. "
                    + "Existing data is retained."
            )
        }
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func availableSchema(_ schema: ModuleSchema) -> some View {
        DisclosureGroup("Available Parameters (\(schema.fields.count))") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(schema.fields) { field in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(field.displayTitle).font(.callout)
                        if let bounds = field.boundsDescription { Text(bounds) }
                        if let value = field.defaultValue { Text("Schema default \(value.entryText)") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.top, 8)
        }
    }

    private func instanceTitle(_ module: ModuleState) -> String {
        if let name = module.name, !name.isEmpty { return "\(module.instance + 1): \(name)" }
        return "Instance \(module.instance + 1)"
    }
}
