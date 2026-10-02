import Foundation

struct WorkflowBaseline {
    var document: PhotoDocument
    var image: ImageEvidence
    var sourceHash: Data
}

@MainActor
enum WorkflowSteps {
    static func importRaw(store: EditorStore, fixture: URL) async throws -> WorkflowBaseline {
        let sourceHash = try fileDigest(fixture)
        await store.importURLs([fixture])
        await store.waitForRender()
        try requireWorkflow(store.documents.count == 1, "RAW import failed: \(store.errorMessage ?? "unknown")")
        guard let document = store.selectedDocument, let frame = store.preview else {
            throw WorkflowFailure("RAW import did not produce a real preview.")
        }
        let image = try ImageEvidence(url: frame.imageURL)
        try requireWorkflow(!document.edits.modules.isEmpty, "Import omitted darktable module state.")
        try requireWorkflow(document.edits.darktableXMP != nil, "Import omitted full darktable XMP.")
        print("PASS RAW copy, darktable preparation, ICC preview")
        return WorkflowBaseline(document: document, image: image, sourceHash: sourceHash)
    }

    static func adjustExposure(store: EditorStore, baseline: WorkflowBaseline) async throws -> ImageEvidence {
        let historyCount = store.history.count
        store.beginEditing("Exposure")
        for value in [0.25, 0.5, 1.0] { store.setExposure(value) }
        store.endEditing()
        await store.waitForRender()
        try requireWorkflow(store.history.count == historyCount + 1, "Slider gesture did not coalesce history.")
        try requireWorkflow(
            store.currentEdits.modules == baseline.document.edits.modules, "Exposure changed base blobs.")
        try requireWorkflow(
            store.currentEdits.darktableXMP == baseline.document.edits.darktableXMP, "Base XMP changed.")
        guard let frame = store.preview else { throw WorkflowFailure("Exposure did not produce a preview.") }
        let image = try ImageEvidence(url: frame.imageURL)
        try requireWorkflow(image.pixelDigest != baseline.image.pixelDigest, "Exposure left pixels unchanged.")
        try requireWorkflow(image.averageLuma > baseline.image.averageLuma, "Exposure did not brighten pixels.")
        store.undo()
        await store.waitForRender()
        guard let undo = store.preview else { throw WorkflowFailure("Undo did not produce a preview.") }
        let restored = try ImageEvidence(url: undo.imageURL)
        try requireWorkflow(restored.pixelDigest == baseline.image.pixelDigest, "Undo did not restore pixels.")
        store.redo()
        await store.waitForRender()
        print("PASS actual exposure, coalesced history, pixel-exact undo and redo")
        return image
    }

    static func reopen(
        store: EditorStore, engine: any PhotoEngine, catalogURL: URL, exposure: ImageEvidence
    ) async throws -> EditorStore {
        try store.saveCatalog()
        let reopened = try EditorStore(engine: engine, catalogURL: catalogURL)
        reopened.start()
        await reopened.waitForRender()
        try requireWorkflow(reopened.currentEdits == store.currentEdits, "Save/reopen changed complete edits.")
        try requireWorkflow(reopened.history == store.history, "Save/reopen changed complete undo history.")
        try requireWorkflow(reopened.documents == store.documents, "Save/reopen changed complete documents.")
        try requireWorkflow(!reopened.hasUnsavedChanges, "Reopened saved catalog is dirty.")
        guard let frame = reopened.preview else { throw WorkflowFailure("Reopen did not render.") }
        let image = try ImageEvidence(url: frame.imageURL)
        try requireWorkflow(image.pixelDigest == exposure.pixelDigest, "Reopen changed developed pixels.")
        print("PASS atomic save and complete history/document reopen")
        return reopened
    }

    static func switchPhotos(store: EditorStore, baseline: WorkflowBaseline, fixture: URL) async throws {
        guard let initial = store.preview else { throw WorkflowFailure("Missing initial preview.") }
        let image = try ImageEvidence(url: initial.imageURL)
        store.setTemperature(4000)
        await store.waitForRender()
        guard let frame = store.preview else { throw WorkflowFailure("White balance did not render.") }
        let whiteBalance = try ImageEvidence(url: frame.imageURL)
        try requireWorkflow(whiteBalance.pixelDigest != image.pixelDigest, "White balance left pixels unchanged.")
        store.undo()
        await store.waitForRender()
        await store.importURLs([fixture])
        guard let secondID = store.selectedAssetID else { throw WorkflowFailure("Second import failed.") }
        store.selectAsset(baseline.document.id)
        store.selectAsset(secondID)
        store.selectAsset(baseline.document.id)
        await store.waitForRender()
        try requireWorkflow(store.preview?.assetID == baseline.document.id, "Stale switching replaced the frame.")
        try requireWorkflow(!store.isRendering, "Cancelled renders left loading stuck.")
        print("PASS actual WB, A/B/A switching, cancellation and current-generation display")
    }

    static func export(
        store: EditorStore, baseline: WorkflowBaseline, fixture: URL, output: URL
    ) async throws {
        store.exportFormat = .png
        store.exportColorSpace = .sRGB
        let destination = output.appendingPathComponent("developed.png")
        await store.export(to: destination, maximumDimension: 1600)
        try requireWorkflow(store.lastExport?.destinationURL == destination, "Export failed.")
        let image = try ImageEvidence(url: destination)
        try requireWorkflow(max(image.width, image.height) == 1600, "Export ignored size limit.")
        try requireWorkflow(!image.profile.isEmpty, "Export omitted ICC.")
        let edits = store.currentEdits
        await store.export(to: output.appendingPathComponent("Missing/export.png"), maximumDimension: 1600)
        try requireWorkflow(store.errorMessage != nil, "Invalid destination did not report an error.")
        try requireWorkflow(store.currentEdits == edits, "Failed export changed edits.")
        try requireWorkflow(try fileDigest(fixture) == baseline.sourceHash, "Original RAW was modified.")
        let repository = CatalogRepository(rootURL: store.catalogURL)
        let copied = try repository.sourceURL(for: baseline.document)
        try requireWorkflow(try fileDigest(copied) == baseline.sourceHash, "Catalog RAW was modified.")
        print("PASS export destination/size/ICC, failure state and unchanged source hashes")
    }
}
