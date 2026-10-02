import Foundation

@MainActor
final class ModuleEditingSession {
    let id = UUID()
    let assetID: UUID
    let catalogID: UUID
    let catalogURL: URL
    let sourceURL: URL
    let baseline: EditState
    let moduleID: UUID
    let label: String
    var expectedEdits: EditState
    var expectedRevision: UInt64
    var prepared: EditState?
    var requestID = UUID()
    var task: Task<ModuleEditingResult, Error>?

    init(document: PhotoDocument, store: EditorStore, moduleID: UUID, label: String) throws {
        assetID = document.id
        catalogID = store.catalogID
        catalogURL = store.catalogURL
        sourceURL = try CatalogRepository(rootURL: store.catalogURL).sourceURL(for: document)
        baseline = document.edits
        expectedEdits = document.edits
        expectedRevision = store.editRevision
        self.moduleID = moduleID
        self.label = label
    }
}

struct ModuleEditingResult: Sendable {
    let baseline: EditState
    let edits: EditState
}
