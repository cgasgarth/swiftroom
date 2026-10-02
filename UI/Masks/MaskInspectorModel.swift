import Combine
import Foundation

struct MaskInspectorContext: Equatable {
    let assetID: UUID?
    let catalogID: UUID
    let catalogURL: URL
    let edits: EditState
    let revision: UInt64
}

enum NewMaskKind: String, CaseIterable, Identifiable {
    case circle, ellipse, gradient, group
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

@MainActor
final class MaskInspectorModel: ObservableObject {
    @Published private(set) var state: MaskState?
    @Published private(set) var selectedFormID: Int32?
    @Published private(set) var selectedModuleID: UUID?
    @Published private(set) var isLoading = false
    @Published private(set) var isApplying = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var draftGeometry: MaskGeometry?
    @Published private(set) var invalidFields: Set<String> = []
    @Published private(set) var draftRevision = UUID()
    @Published var draftName = ""
    @Published var draftOpacity: Double = 100
    @Published var draftMode: UInt32 = 24
    @Published var draftReversed = false
    @Published var draftGroupID: Int32 = 0

    let store: EditorStore
    private var expectedContext: MaskInspectorContext?
    private var loadTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var loadTicket = UUID()
    private var applyTicket = UUID()

    init(store: EditorStore) { self.store = store }

    var context: MaskInspectorContext {
        MaskInspectorContext(
            assetID: store.selectedAssetID, catalogID: store.catalogID,
            catalogURL: store.catalogURL, edits: store.currentEdits, revision: store.editRevision)
    }

    var selectedForm: MaskForm? { state?.forms.first { $0.id == selectedFormID } }
    var selectedBlend: BlendState? { state?.blends.first { $0.moduleID == selectedModuleID } }
    var modules: [ModuleState] { store.currentEdits.modules.sorted { $0.order < $1.order } }
    var groups: [MaskForm] {
        state?.forms.filter {
            if case .group = $0.geometry { return true }
            return false
        } ?? []
    }
    var canEdit: Bool {
        store.engine is any MaskEditingEngine && store.selectedAssetID != nil && state != nil
            && !isLoading && !isApplying && context == expectedContext
    }
    var hasSupportedBlendSeed: Bool {
        guard let blend = selectedBlend, blend.version == 14,
            let module = modules.first(where: { $0.id == blend.moduleID }),
            module.blendVersion == 14, let seed = module.blendParameters, !seed.isEmpty else { return false }
        return seed == blend.parameters
    }
    var canEditBlend: Bool { canEdit && hasSupportedBlendSeed }
    var nameIsValid: Bool { draftName.utf8.count <= 127 }
    var hasChanges: Bool {
        let formChanged = selectedForm.map { draftName != $0.name || draftGeometry != $0.geometry } ?? false
        return formChanged || !blendChanges.isEmpty
    }
    var canApply: Bool { canEdit && hasChanges && nameIsValid && invalidFields.isEmpty }
    var selectedReferences: [String] {
        guard let id = selectedFormID else { return [] }
        let forms =
            state?.forms.filter { form in
                if case .group(let members) = form.geometry { return members.contains { $0.maskID == id } }
                return false
            }.map(\.name) ?? []
        let blends =
            state?.blends.filter { $0.maskID == id }.map { blend in
                modules.first { $0.id == blend.moduleID }.map(moduleTitle) ?? "Retained module"
            } ?? []
        return forms + blends
    }

    func activate() {
        cancel()
        state = nil
        expectedContext = context
        errorMessage = nil
        statusMessage = nil
        guard store.selectedAssetID != nil else { return }
        guard store.engine is any MaskEditingEngine else {
            errorMessage = "This engine does not expose masks or module blending. Existing data is retained."
            return
        }
        let ticket = UUID()
        loadTicket = ticket
        let startingContext = context
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { if loadTicket == ticket { isLoading = false } }
            do {
                let result = try await store.currentMaskState()
                try Task.checkCancellation()
                guard loadTicket == ticket, context == startingContext else { return }
                state = result
                expectedContext = startingContext
                if !result.forms.contains(where: { $0.id == selectedFormID }) {
                    selectedFormID = result.forms.first?.id
                }
                if !modules.contains(where: { $0.id == selectedModuleID }) {
                    selectedModuleID = result.blends.first?.moduleID
                }
                restoreDrafts()
            } catch is CancellationError {} catch {
                guard loadTicket == ticket, context == startingContext else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func synchronize() {
        guard context != expectedContext || (!isLoading && state == nil) else { return }
        let discarded = hasChanges
        activate()
        if discarded { statusMessage = "Draft discarded because the photo or its history changed." }
    }

    func chooseForm(_ id: Int32?) {
        guard !isApplying else { return }
        let discarded = hasChanges
        selectedFormID = id
        restoreDrafts()
        statusMessage = discarded ? "Unapplied draft discarded when changing selection." : nil
    }

    func chooseModule(_ id: UUID?) {
        guard !isApplying, selectedModuleID != id else { return }
        let discarded = hasChanges
        selectedModuleID = id
        restoreDrafts()
        statusMessage = discarded ? "Unapplied draft discarded when changing selection." : nil
    }

    func setGeometry(_ value: MaskGeometry) {
        guard canEdit, selectedForm?.geometry != nil else { return }
        draftGeometry = value
    }

    func setValidity(_ field: String, valid: Bool) {
        if valid { invalidFields.remove(field) } else { invalidFields.insert(field) }
    }

    func discard() {
        restoreDrafts()
        statusMessage = nil
    }

    func apply() {
        guard canApply else { return }
        var mutations: [MaskMutation] = []
        if let form = selectedForm, draftName != form.name || draftGeometry != form.geometry {
            mutations.append(
                .update(
                    id: form.id, name: draftName != form.name ? draftName : nil,
                    geometry: draftGeometry != form.geometry ? draftGeometry : nil))
        }
        submit(MaskEdit(mutations: mutations, blends: blendChanges), label: "Masks and blending")
    }

    func add(_ kind: NewMaskKind) {
        guard canEdit, !hasChanges, let highest = state?.forms.map(\.id).max(), highest < Int32.max else {
            if canEdit, !hasChanges, state?.forms.isEmpty == true { create(kind, id: 1) }
            return
        }
        create(kind, id: max(1, highest + 1))
    }

    func removeSelected() {
        guard canEdit, !hasChanges, selectedReferences.isEmpty, let id = selectedFormID else { return }
        submit(MaskEdit(mutations: [.delete(id: id)]), label: "Remove mask")
    }

    func updateMember(_ index: Int, mutation: (inout MaskGroupMember) -> Void) {
        guard canEdit, case .group(var members) = draftGeometry, members.indices.contains(index) else {
            return
        }
        mutation(&members[index])
        draftGeometry = .group(members)
    }

    func moveMember(_ index: Int, by offset: Int) {
        guard canEdit, case .group(var members) = draftGeometry,
            members.indices.contains(index), members.indices.contains(index + offset)
        else { return }
        members.swapAt(index, index + offset)
        draftGeometry = .group(members)
        invalidFields = invalidFields.filter { !$0.hasPrefix("member.") }
        draftRevision = UUID()
    }

    func removeMember(_ index: Int) {
        guard canEdit, case .group(var members) = draftGeometry, members.indices.contains(index) else {
            return
        }
        members.remove(at: index)
        draftGeometry = .group(members)
        invalidFields = invalidFields.filter { !$0.hasPrefix("member.") }
        draftRevision = UUID()
    }

    func addMember(_ id: Int32) {
        guard canEdit, case .group(var members) = draftGeometry, canAddMember(id) else { return }
        members.append(MaskGroupMember(maskID: id, opacity: 1, operation: .union))
        draftGeometry = .group(members)
    }

    func canAddMember(_ id: Int32) -> Bool {
        guard let selectedFormID, id != selectedFormID,
            state?.forms.contains(where: { $0.id == id }) == true
        else { return false }
        var visited: Set<Int32> = []
        return !reaches(id, target: selectedFormID, visited: &visited)
    }

    func moduleTitle(_ module: ModuleState) -> String {
        let name = module.name.flatMap { $0.isEmpty ? nil : $0 }
        return "\(name ?? module.operation) · \(module.instance + 1)"
    }

    func cancel() {
        loadTask?.cancel()
        applyTask?.cancel()
        loadTicket = UUID()
        applyTicket = UUID()
        isLoading = false
        isApplying = false
    }

    func cancelApply() {
        cancel()
        activate()
        statusMessage = "Mask edit cancelled."
    }
    func waitForLoad() async { await loadTask?.value }
    func waitForApply() async {
        await applyTask?.value
        await loadTask?.value
    }
}

extension MaskInspectorModel {
    private var blendChanges: [ModuleBlendMutation] {
        guard canEditBlend, let original = selectedBlend else { return [] }
        var patch = BlendPatch()
        if draftOpacity != original.opacity { patch.opacity = draftOpacity }
        if draftMode != original.mode & 0xFF { patch.mode = BlendMode(rawValue: draftMode) }
        if draftReversed != (original.mode & 0x8000_0000 != 0) { patch.reversed = draftReversed }
        if draftGroupID != (original.maskMode.contains(.drawn) ? original.maskID : 0) {
            patch.maskID = draftGroupID
            patch.maskMode = original.maskMode
            if draftGroupID == 0 {
                patch.maskMode?.remove(.drawn)
            } else {
                patch.maskMode?.formUnion([.enabled, .drawn])
            }
        }
        return patch == BlendPatch() ? [] : [ModuleBlendMutation(moduleID: original.moduleID, patch: patch)]
    }

    private func restoreDrafts() {
        draftName = selectedForm?.name ?? ""
        draftGeometry = selectedForm?.geometry
        draftOpacity = selectedBlend?.opacity ?? 100
        draftMode = (selectedBlend?.mode ?? 24) & 0xFF
        draftReversed = (selectedBlend?.mode ?? 0) & 0x8000_0000 != 0
        draftGroupID = selectedBlend?.maskMode.contains(.drawn) == true ? selectedBlend?.maskID ?? 0 : 0
        invalidFields.removeAll()
        draftRevision = UUID()
    }

    private func create(_ kind: NewMaskKind, id: Int32) {
        let point = MaskPoint(horizontal: 0.5, vertical: 0.5)
        let geometry: MaskGeometry
        switch kind {
        case .circle: geometry = .circle(CircleMask(center: point, radius: 0.15, feather: 0.05))
        case .ellipse:
            geometry = .ellipse(
                EllipseMask(
                    center: point, radius: MaskPoint(horizontal: 0.2, vertical: 0.1),
                    rotation: 0, feather: 0.05, featherMode: .equidistant))
        case .gradient:
            geometry = .gradient(
                GradientMask(
                    anchor: point, rotation: 0, compression: 0.2,
                    steepness: 0, curvature: 0, transition: .linear))
        case .group:
            let members = selectedFormID.map { [MaskGroupMember(maskID: $0, opacity: 1, operation: .union)] }
            geometry = .group(members ?? [])
        }
        selectedFormID = id
        submit(
            MaskEdit(mutations: [
                .create(
                    MaskDefinition(
                        id: id, name: "\(kind.title) \(id)",
                        geometry: geometry))
            ]), label: "Add \(kind.title.lowercased()) mask")
    }

    private func submit(_ edit: MaskEdit, label: String) {
        guard canEdit, let expectedContext, let assetID = expectedContext.assetID else { return }
        let ticket = UUID()
        applyTicket = ticket
        isApplying = true
        errorMessage = nil
        applyTask = Task { [weak self] in
            guard let self else { return }
            defer { if applyTicket == ticket { isApplying = false } }
            do {
                let accepted = try await store.commitCurrentMasks(
                    assetID: assetID,
                    catalogID: expectedContext.catalogID, expectedEdits: expectedContext.edits,
                    expectedRevision: expectedContext.revision, edit: edit, label: label)
                try Task.checkCancellation()
                guard applyTicket == ticket else { return }
                activate()
                statusMessage =
                    accepted
                    ? "Applied. Undo restores the previous masks and blending."
                    : "Draft discarded because the photo or its history changed."
            } catch is CancellationError {} catch {
                guard applyTicket == ticket, context == expectedContext else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func reaches(_ id: Int32, target: Int32, visited: inout Set<Int32>) -> Bool {
        if id == target { return true }
        guard visited.insert(id).inserted,
            case .group(let members) = state?.forms.first(where: { $0.id == id })?.geometry
        else { return false }
        return members.contains { reaches($0.maskID, target: target, visited: &visited) }
    }
}
