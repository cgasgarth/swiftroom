import Foundation

@MainActor
enum PreviewWorkflow {
    static func verify(store: EditorStore, output: URL) async throws {
        guard let startingAssetID = store.selectedAssetID else { throw WorkflowFailure("No selected asset.") }
        for document in store.documents where store.cachedPreviews[document.id] == nil {
            store.selectAsset(document.id)
            await store.waitForRender()
        }
        store.selectAsset(startingAssetID)
        await store.waitForRender()
        guard let first = store.preview else { throw WorkflowFailure("Missing preview for lifetime validation.") }
        try requireWorkflow(store.cachedPreviews.count == store.documents.count, "Visited previews were lost.")
        let retained = store.cachedPreviews.values.filter { $0.assetID != first.assetID }
        store.previewDidPresent(first.imageURL)
        await store.waitForPreviewCleanup()
        store.retryRender()
        await store.waitForRender()
        guard let replacement = store.preview else { throw WorkflowFailure("Replacement preview is missing.") }
        try requireWorkflow(replacement.imageURL != first.imageURL, "Preview replacement reused a frame.")
        try requireWorkflow(FileManager.default.fileExists(atPath: first.imageURL.path),
            "Displayed preview was deleted before consumer acknowledgement.")
        store.previewDidPresent(replacement.imageURL)
        await store.waitForPreviewCleanup()
        try requireWorkflow(!FileManager.default.fileExists(atPath: first.imageURL.path),
            "Displaced accepted preview was retained after acknowledgement.")
        for photo in retained {
            try requireWorkflow(FileManager.default.fileExists(atPath: photo.imageURL.path),
                "Switching deleted another asset's retained preview.")
        }
        store.clearAssetSelection()
        store.previewDidClear()
        await store.waitForPreviewCleanup()
        try requireWorkflow(store.cachedPreviews.count == store.documents.count,
            "Clearing selection discarded catalog previews.")
        let catalogFrames = Array(store.cachedPreviews.values)
        try store.openCatalog(at: output.appendingPathComponent("EmptyCatalog"))
        try requireWorkflow(store.cachedPreviews.isEmpty, "Catalog switching retained the previous preview map.")
        store.previewDidClear()
        await store.waitForPreviewCleanup()
        for photo in catalogFrames {
            try requireWorkflow(!FileManager.default.fileExists(atPath: photo.imageURL.path),
                "Catalog preview survived consumer release.")
        }
        print("PASS retained preview ownership, acknowledgement, asset switching and catalog cleanup")
    }
}
