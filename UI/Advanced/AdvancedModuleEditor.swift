import Combine
import Foundation

struct AdvancedOperation: Identifiable {
    let operation: String
    let title: String
    let descriptor: ProcessingModule?
    let instanceCount: Int
    var id: String { operation }
}

private struct AdvancedModuleContext: Equatable {
    let assetID: UUID?
    let catalogID: UUID?
    let catalogURL: URL?
}

@MainActor
final class AdvancedModuleEditor: ObservableObject {
    @Published private(set) var descriptors: [ProcessingModule] = []
    @Published private(set) var selectedOperation = ""
    @Published private(set) var selectedModuleID: UUID?
    @Published private(set) var schema: ModuleSchema?
    @Published private(set) var values: [String: ModuleParameterValue] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isApplying = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var invalidFields: Set<String> = []
    @Published private(set) var editorRevision = UUID()
    @Published var draftName = ""
    @Published var draftEnabled = false

    let store: EditorStore
    private var originalModule: ModuleState?
    private var originalValues: [String: ModuleParameterValue] = [:]
    private var expectedEdits = EditState.original
    private var expectedAssetID: UUID?
    private var expectedCatalogURL: URL?
    private var expectedCatalogID: UUID?
    private var loadTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var loadTicket = UUID()
    private var applyTicket = UUID()
    private var normalizedEdits: EditState?
    private var normalizedSourceEdits: EditState?
    private var normalizedContext: AdvancedModuleContext?

    init(store: EditorStore) { self.store = store }

    var operations: [AdvancedOperation] {
        let grouped = Dictionary(grouping: store.currentEdits.modules, by: \.operation)
        let known = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.operation, $0) })
        return Set(grouped.keys).union(known.keys).map { operation in
            AdvancedOperation(
                operation: operation, title: known[operation]?.title ?? operation,
                descriptor: known[operation], instanceCount: grouped[operation]?.count ?? 0)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var instances: [ModuleState] {
        store.currentEdits.modules.filter { $0.operation == selectedOperation }.sorted {
            $0.instance == $1.instance ? $0.order < $1.order : $0.instance < $1.instance
        }
    }

    var selectedDescriptor: ProcessingModule? {
        descriptors.first { $0.operation == selectedOperation }
    }

    var canEdit: Bool {
        store.capabilities.supportsModuleEditing && originalModule != nil && schema != nil
            && !isLoading && !isApplying && matchesContext && expectedEdits == store.currentEdits
    }

    var hasLoadedValues: Bool { originalModule != nil }

    var hasChanges: Bool {
        guard let originalModule else { return false }
        return !changedValues.isEmpty || draftName != (originalModule.name ?? "")
            || draftEnabled != originalModule.enabled
    }

    var nameIsValid: Bool { draftName.utf8.count <= 127 }

    var canApply: Bool { canEdit && hasChanges && invalidFields.isEmpty && nameIsValid }

    var resettableFields: [ModuleParameterField] {
        schema?.fields.filter { field in
            guard values[field.name] != nil, let value = field.defaultValue else { return false }
            return field.accepts(value)
        } ?? []
    }

    func activate() {
        loadTask?.cancel()
        applyTask?.cancel()
        applyTicket = UUID()
        isApplying = false
        let ticket = UUID()
        loadTicket = ticket
        isLoading = true
        clearEditor()
        expectedEdits = store.currentEdits
        expectedAssetID = store.selectedAssetID
        expectedCatalogURL = store.catalogURL
        expectedCatalogID = store.catalogID
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await store.engine.modules()
                try Task.checkCancellation()
                guard loadTicket == ticket else { return }
                descriptors = result
                selectInitialOperation()
            } catch is CancellationError {} catch {
                guard loadTicket == ticket else { return }
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func chooseOperation(_ operation: String) {
        selectedOperation = operation
        selectedModuleID = instances.first?.id
        reloadSelection()
    }

    func chooseInstance(_ id: UUID) {
        selectedModuleID = id
        reloadSelection()
    }

    func synchronize() {
        guard !isApplying else { return }
        guard !matchesContext || expectedEdits != store.currentEdits else { return }
        let discarded = hasChanges
        if !operations.contains(where: { $0.operation == selectedOperation }) {
            selectInitialOperation()
        } else {
            if !instances.contains(where: { $0.id == selectedModuleID }) {
                selectedModuleID = instances.first?.id
            }
            reloadSelection()
        }
        if discarded { statusMessage = "Draft discarded because the photo or its history changed." }
    }

    func setValue(_ name: String, value: ModuleParameterValue) {
        guard canEdit, let field = schema?.fields.first(where: { $0.name == name }),
            field.accepts(value), let original = originalValues[name]
        else { return }
        if field.valuesEqual(original, value) {
            values[name] = original
        } else {
            values[name] = value
        }
        statusMessage = nil
    }

    func setValidity(_ name: String, valid: Bool) {
        if valid { invalidFields.remove(name) } else { invalidFields.insert(name) }
    }

    func resetDefaults() {
        guard canEdit else { return }
        for field in resettableFields {
            if let value = field.defaultValue { setValue(field.name, value: value) }
        }
        invalidFields.removeAll()
        editorRevision = UUID()
    }

    func discard() {
        guard let originalModule else { return }
        values = originalValues
        draftName = originalModule.name ?? ""
        draftEnabled = originalModule.enabled
        invalidFields.removeAll()
        editorRevision = UUID()
        statusMessage = nil
    }

    func apply() {
        guard canApply, let module = originalModule, let assetID = expectedAssetID,
            let catalogID = expectedCatalogID else { return }
        let changes = changedValues
        var updated = module
        updated.enabled = draftEnabled
        updated.name = draftName == (module.name ?? "") ? module.name : draftName
        let edits = expectedEdits
        let title = selectedDescriptor?.title ?? module.operation
        let label = title.prefix(1).uppercased() + title.dropFirst()
        let catalogURL = expectedCatalogURL
        let ticket = UUID()
        applyTicket = ticket
        isApplying = true
        errorMessage = nil
        applyTask = Task { [weak self] in
            guard let self else { return }
            defer { if applyTicket == ticket { isApplying = false } }
            do {
                guard store.catalogURL == catalogURL else { throw CancellationError() }
                let applied = try await store.commitCurrentModule(
                    assetID: assetID, catalogID: catalogID,
                    expectedEdits: edits, module: updated, values: changes,
                    label: label)
                try Task.checkCancellation()
                guard applyTicket == ticket, matchesContext else { return }
                guard applied else {
                    reloadSelection()
                    statusMessage = "Draft discarded because the photo or its history changed."
                    return
                }
                reloadSelection()
                statusMessage = "Changes applied."
            } catch is CancellationError {
                if applyTicket == ticket { reloadSelection() }
            } catch {
                if applyTicket == ticket, matchesContext { errorMessage = error.localizedDescription }
            }
        }
    }

    func cancel() {
        loadTask?.cancel()
        applyTask?.cancel()
        applyTicket = UUID()
        isApplying = false
        loadTicket = UUID()
        isLoading = false
    }

    func waitForLoad() async {
        while isLoading { await loadTask?.value }
    }

    func waitForApply() async { await applyTask?.value }

    private var matchesContext: Bool {
        expectedAssetID == store.selectedAssetID && expectedCatalogURL == store.catalogURL
            && expectedCatalogID == store.catalogID
    }

    private var changedValues: [String: ModuleParameterValue] {
        values.filter { originalValues[$0.key] != $0.value }
    }
}

extension AdvancedModuleEditor {

    private func selectInitialOperation() {
        let retained = operations.filter { $0.instanceCount > 0 }
        let operation =
            retained.first { $0.operation == selectedOperation }
            ?? retained.first { $0.operation == "exposure" } ?? retained.first ?? operations.first
        chooseOperation(operation?.operation ?? "")
    }

    private func clearEditor() {
        schema = nil
        values = [:]
        originalValues = [:]
        originalModule = nil
        invalidFields = []
        errorMessage = nil
        statusMessage = nil
        editorRevision = UUID()
    }

    private func reloadSelection() {
        loadTask?.cancel()
        clearEditor()
        expectedEdits = store.currentEdits
        expectedAssetID = store.selectedAssetID
        expectedCatalogURL = store.catalogURL
        expectedCatalogID = store.catalogID
        let module = instances.first { $0.id == selectedModuleID }
        let operation = selectedOperation
        let ticket = UUID()
        loadTicket = ticket
        guard !operation.isEmpty else {
            isLoading = false
            return
        }
        if selectedDescriptor?.hasIntrospection == false {
            isLoading = false
            return
        }
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { if loadTicket == ticket { isLoading = false } }
            do {
                let result = try await store.engine.schema(for: operation)
                try Task.checkCancellation()
                guard loadTicket == ticket, matchesContext, expectedEdits == store.currentEdits else {
                    return
                }
                schema = result
                guard let module else { return }
                let actual = try await effectiveModule(module)
                let decoded = try await decode(actual, schema: result)
                try Task.checkCancellation()
                guard loadTicket == ticket, matchesContext, expectedEdits == store.currentEdits else {
                    return
                }
                originalModule = actual
                originalValues = decoded
                values = decoded
                draftName = actual.name ?? ""
                draftEnabled = actual.enabled
            } catch is CancellationError {} catch {
                guard loadTicket == ticket, matchesContext else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func decode(_ module: ModuleState, schema: ModuleSchema) async throws -> [String: ModuleParameterValue] {
        guard schema.parametersVersion == module.version, schema.parametersSize == module.parameters.count else {
            throw PhotoEngineError.unsupported("This retained parameter version has no compatible editor.")
        }
        return try await store.engine.parameters(for: module)
    }

    private func effectiveModule(_ module: ModuleState) async throws -> ModuleState {
        guard expectedEdits.exposureEV != 0 || expectedEdits.temperature != nil || expectedEdits.tint != 0 else {
            return module
        }
        let context = AdvancedModuleContext(assetID: expectedAssetID, catalogID: expectedCatalogID,
            catalogURL: expectedCatalogURL)
        if normalizedSourceEdits != expectedEdits || normalizedContext != context {
            guard let document = store.selectedDocument else { throw CancellationError() }
            let source = try CatalogRepository(rootURL: store.catalogURL).sourceURL(for: document)
            let sourceEdits = expectedEdits
            let prepared = try await store.engine.prepare(sourceURL: source, edits: sourceEdits)
            try Task.checkCancellation()
            normalizedEdits = prepared.edits
            normalizedSourceEdits = sourceEdits
            normalizedContext = context
        }
        guard var actual = normalizedEdits?.modules.first(where: {
            $0.operation == module.operation && $0.instance == module.instance
        }) else {
            throw PhotoEngineError.unsupported("The effective module instance is unavailable.")
        }
        actual.id = module.id
        return actual
    }
}
