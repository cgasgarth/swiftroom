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
            adjustmentSelection
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
                moduleContent
                moduleManagement
                operationBrowser
                supportNotice
                if editor.hasChanges || !editor.invalidFields.isEmpty || !editor.nameIsValid { draftActions }
            }
            if let status = editor.statusMessage, !editor.hasChanges {
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

    private var adjustmentSelection: some View {
        HStack {
            Picker("Adjustment", selection: Binding(
                get: { editor.selectedOperation }, set: editor.chooseOperation
            )) {
                if editor.selectedOperation.isEmpty { Text("Choose Adjustment").tag("") }
                ForEach(editor.operations.filter { $0.instanceCount > 0 || $0.operation == editor.selectedOperation }) {
                    Text(operationTitle($0)).tag($0.operation)
                }
            }
            .labelsHidden().pickerStyle(.menu)
            .disabled(editor.isApplying || editor.operations.isEmpty)
            .accessibilityLabel("Adjustment").accessibilityIdentifier("advanced.operation")
            Spacer(minLength: 4)
            if editor.hasLoadedValues {
                Toggle("Enabled", isOn: $editor.draftEnabled)
                    .toggleStyle(.checkbox).disabled(!editor.canEdit)
                    .accessibilityIdentifier("advanced.enabled")
            }
        }
    }

    private var operationBrowser: some View {
        DisclosureGroup("Search Adjustments") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Find an adjustment by name, then choose a match.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Search adjustments", text: $search)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("advanced.search")
                Toggle("Include unused adjustments", isOn: $showsAllOperations)
                    .toggleStyle(.checkbox).accessibilityIdentifier("advanced.allOperations")
                if filteredOperations.isEmpty {
                    Text("No adjustments match this search.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Picker("Matches", selection: Binding(
                        get: { editor.selectedOperation }, set: editor.chooseOperation
                    )) {
                        ForEach(filteredOperations) { Text(operationTitle($0)).tag($0.operation) }
                        if !filteredOperations.contains(where: { $0.operation == editor.selectedOperation }) {
                            Text("Current Adjustment").tag(editor.selectedOperation)
                        }
                    }
                    .pickerStyle(.menu).disabled(editor.isApplying)
                    .accessibilityIdentifier("advanced.searchResults")
                }
            }.padding(.top, 6)
        }
    }

    private func operationTitle(_ operation: AdvancedOperation) -> String {
        let title = operation.title.prefix(1).uppercased() + operation.title.dropFirst()
        return title + (operation.instanceCount > 1 ? " (\(operation.instanceCount))" : "")
    }

    private var filteredOperations: [AdvancedOperation] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return editor.operations.filter { operation in
            (showsAllOperations || operation.instanceCount > 0)
                && (query.isEmpty || operation.title.localizedStandardContains(query)
                    || operation.operation.localizedStandardContains(query))
        }
    }

    private var moduleManagement: some View {
        DisclosureGroup("Adjustment Options") {
            VStack(alignment: .leading, spacing: 10) {
                if editor.instances.count > 1 {
                    Picker("Instance", selection: Binding(
                        get: { editor.selectedModuleID },
                        set: { if let id = $0 { editor.chooseInstance(id) } }
                    )) {
                        ForEach(editor.instances) { Text(instanceTitle($0)).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.menu).disabled(editor.isApplying)
                    .accessibilityIdentifier("advanced.instance")
                }
                if editor.hasLoadedValues {
                    HStack {
                        Text("Name")
                        TextField("Adjustment name", text: Binding(
                            get: { editor.draftName.advancedInstanceLabel },
                            set: { text in
                                if text != editor.draftName.advancedInstanceLabel { editor.draftName = text }
                            }
                        ))
                        .textFieldStyle(.roundedBorder).disabled(!editor.canEdit)
                        .accessibilityLabel("Adjustment name").accessibilityIdentifier("advanced.name")
                    }
                    if !editor.nameIsValid {
                        Text("Use at most 127 UTF-8 bytes for the name.")
                            .font(.caption).foregroundStyle(.red)
                    }
                    Button("Reset Parameters", action: editor.resetDefaults)
                        .disabled(!editor.canEdit || editor.resettableFields.isEmpty)
                        .help("Use darktable’s declared defaults for all editable parameters. Apply to keep the reset.")
                        .accessibilityIdentifier("advanced.resetAll")
                }
                DisclosureGroup("Technical Details") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Operation: \(editor.selectedOperation)")
                        if let module = editor.instances.first(where: { $0.id == editor.selectedModuleID }) {
                            Text("Version \(module.version) · Instance \(module.instance + 1)")
                            if let name = module.name { Text("Stored name: \(name)") }
                        }
                    }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 6)
                }
            }.padding(.top, 6)
        }
    }

    @ViewBuilder
    private var moduleContent: some View {
        if editor.instances.isEmpty {
            Text("This adjustment is not used in the photo. Adding adjustments is not yet available.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let schema = editor.schema { availableSchema(schema) }
        } else if editor.selectedDescriptor?.hasIntrospection == false {
            Text("These settings cannot be edited yet. The adjustment’s current effects are preserved.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if let schema = editor.schema, editor.hasLoadedValues, !editor.isLoading {
            VStack(alignment: .leading, spacing: 12) {
                if schema.fields.isEmpty {
                    Text("This adjustment has no supported numeric settings.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    AdvancedModuleFields(
                        schema: schema, values: editor.values,
                        onSet: editor.setValue, onValidity: editor.setValidity
                    )
                    .id(editor.editorRevision).disabled(!editor.canEdit)
                }
            }
        }
    }

    private var draftActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pending Changes").font(.callout.weight(.medium))
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
                    ? "Apply adds one undo step. Then save the catalog to keep these edits."
                    : "Correct invalid values before applying."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var supportNotice: some View {
        DisclosureGroup("Editing Support") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Unit labels are shown where verified; other values use darktable’s stored scale.")
                Text("Use Masks for numeric mask geometry and supported blending. Curve editors, parametric masks, "
                    + "mask drawing and new instances are unavailable. Existing edits are preserved.")
            }
            .padding(.top, 6)
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
                        if let value = field.defaultValue { Text("Default \(field.displayText(for: value))") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.top, 8)
        }
    }

    private func instanceTitle(_ module: ModuleState) -> String {
        if let name = module.name, !name.isEmpty { return "\(module.instance + 1): \(name.advancedInstanceLabel)" }
        return "Instance \(module.instance + 1)"
    }
}
