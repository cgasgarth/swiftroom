import SwiftUI

@MainActor
struct MaskInspectorView: View {
    @ObservedObject var store: EditorStore
    let selectedModuleID: UUID?
    @StateObject private var model: MaskInspectorModel
    @State private var search = ""
    @State private var newKind = NewMaskKind.circle

    init(store: EditorStore, selectedModuleID: UUID? = nil) {
        self.store = store
        self.selectedModuleID = selectedModuleID
        _model = StateObject(wrappedValue: MaskInspectorModel(store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.selectedAssetID == nil {
                Text("Choose a photo to inspect masks and module blending.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                maskBrowser
                if model.isLoading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Reading masks and blending…").foregroundStyle(.secondary)
                    }
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .accessibilityIdentifier("masks.error")
                    Button("Reload", action: model.activate).disabled(model.isApplying)
                        .accessibilityIdentifier("masks.reload")
                }
                if let form = model.selectedForm { formEditor(form) }
                Divider()
                MaskBlendFields(model: model)
                draftActions
                Text(
                    "Numeric positions use normalized source-mask coordinates. Canvas drawing and moving "
                        + "are unavailable until orientation, crop, lens and distortion mapping is verified."
                )
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let status = model.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("masks.status")
            }
        }
        .accessibilityIdentifier("masks.inspector")
        .task(
            id: MaskInspectorContext(
                assetID: store.selectedAssetID, catalogID: store.catalogID,
                catalogURL: store.catalogURL, edits: store.currentEdits, revision: store.editRevision)
        ) { model.synchronize() }
        .onAppear { model.chooseModule(selectedModuleID) }
        .onChange(of: selectedModuleID) { _, id in model.chooseModule(id) }
        .onDisappear { model.cancel() }
    }

    private var filteredForms: [MaskForm] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.state?.forms.filter { form in
            query.isEmpty || form.name.localizedStandardContains(query)
                || form.geometryTitle.localizedStandardContains(query) || String(form.id).contains(query)
        } ?? []
    }

    private var maskBrowser: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search masks and groups", text: $search).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("masks.search")
            if filteredForms.isEmpty {
                Text(search.isEmpty ? "No masks in this photo." : "No masks match this search.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                List(selection: Binding(get: { model.selectedFormID }, set: model.chooseForm)) {
                    ForEach(filteredForms) { form in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(form.name.isEmpty ? "Mask \(form.id)" : form.name)
                                Text("\(form.geometryTitle) · \(form.id)").font(.caption).foregroundStyle(
                                    .secondary)
                            }
                        } icon: {
                            Image(systemName: form.symbol)
                        }
                        .tag(form.id).accessibilityIdentifier("masks.form.\(form.id)")
                    }
                }
                .listStyle(.inset).frame(height: min(220, max(90, CGFloat(filteredForms.count) * 48)))
                .disabled(model.isApplying).accessibilityIdentifier("masks.list")
            }
            HStack {
                Picker("New mask", selection: $newKind) {
                    ForEach(NewMaskKind.allCases) { kind in Text(kind.title).tag(kind) }
                }.labelsHidden().accessibilityLabel("New mask kind")
                    .accessibilityIdentifier("masks.newKind")
                Button("Add Mask") { model.add(newKind) }
                    .disabled(!model.canEdit || model.hasChanges).accessibilityIdentifier("masks.add")
            }
        }
    }

    private func formEditor(_ form: MaskForm) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack {
                Text(form.geometryTitle).font(.headline)
                Spacer()
                Button("Remove", role: .destructive, action: model.removeSelected)
                    .disabled(!model.canEdit || model.hasChanges || !model.selectedReferences.isEmpty)
                    .accessibilityIdentifier("masks.remove")
            }
            TextField("Mask name", text: $model.draftName).textFieldStyle(.roundedBorder)
                .disabled(!model.canEdit).accessibilityIdentifier("masks.name")
            if !model.nameIsValid {
                Text("Names may contain at most 127 UTF-8 bytes.").font(.caption).foregroundStyle(.red)
            }
            if !model.selectedReferences.isEmpty {
                Text(
                    "Used by: \(model.selectedReferences.joined(separator: ", ")). Remove references before deleting."
                )
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            MaskGeometryFields(model: model)
            Text(
                "Engine type \(form.type) · version \(form.version) · \(form.pointData.count) retained bytes"
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var draftActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Discard", action: model.discard)
                    .disabled(!model.canEdit || (!model.hasChanges && model.invalidFields.isEmpty))
                    .accessibilityIdentifier("masks.discard")
                Spacer()
                if model.isApplying {
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: model.cancelApply).accessibilityIdentifier("masks.cancel")
                } else {
                    Button("Apply", action: model.apply).buttonStyle(.borderedProminent)
                        .disabled(!model.canApply).accessibilityIdentifier("masks.apply")
                }
            }
            Text(
                model.hasChanges
                    ? "Unapplied draft. Apply records one undoable adjustment."
                    : "Existing masks and blend fields are retained."
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
