import Foundation

@MainActor
enum EditingRegressionWorkflow {
    static func verify(store: EditorStore) async throws {
        try await cancelAfterDisplayChange(store: store)
        try await resetThenAsShot(store: store)
    }

    private static func cancelAfterDisplayChange(store: EditorStore) async throws {
        guard let assetID = store.selectedAssetID,
              let module = store.currentEdits.modules.first(where: { $0.operation == "exposure" }) else {
            throw WorkflowFailure("Missing real module for display-only cancellation regression.")
        }
        let baseline = store.currentEdits
        let history = store.history
        for fullResolution in [false, true] {
            guard let editingID = store.beginCurrentModuleEditing(assetID: assetID, catalogID: store.catalogID,
                expectedEdits: baseline, moduleID: module.id, label: "Display cancellation") else {
                throw WorkflowFailure("Could not start display cancellation gesture.")
            }
            let accepted = try await store.previewCurrentModule(editingID: editingID, module: module,
                values: ["exposure": .number(1.5)])
            try requireWorkflow(accepted, "Display cancellation sample was rejected.")
            try requireWorkflow(store.isUpdatingEdits && !store.isProcessingEdits,
                                "Open gesture lost its pending barrier between helper work and rendering.")
            try requireWorkflow(!store.prepareToClose(.save), "Idle open gesture permitted premature close-save.")
            do {
                try store.saveCatalog()
                throw WorkflowFailure("Idle open gesture permitted premature direct save.")
            } catch CatalogError.invalid { }
            if fullResolution { store.zoomToActualSize() } else { store.retryRender() }
            store.cancelCurrentModuleEditing(editingID)
            await store.waitForRender()
            try requireWorkflow(store.currentEdits == baseline && store.history == history,
                                "Display-only change caused cancellation to commit instead of restore.")
            try requireWorkflow(!store.isUpdatingEdits, "Cancelled gesture left the pending barrier active.")
            if fullResolution {
                try requireWorkflow(store.isFullResolutionPreview,
                                    "Accepted full developed preview lost its request-backed resolution flag.")
            }
        }
        store.zoomToFit()
        store.clearError()
        print("PASS open-gesture save barrier, retry/actual-size cancellation, accepted full-resolution request flag")
    }

    private static func resetThenAsShot(store: EditorStore) async throws {
        let startingIndex = store.selectedDocument?.historyIndex ?? 0
        let startingEdits = store.currentEdits
        store.resetEdits()
        await store.waitForRender()
        guard let baselineFrame = store.preview else { throw WorkflowFailure("Reset did not render real RAW pixels.") }
        let baseline = try ImageEvidence(url: baselineFrame.imageURL)
        store.setTemperature(4000)
        await store.waitForRender()
        let custom = store.currentEdits
        try requireWorkflow(custom.modules.isEmpty && custom.temperature == 4000,
                            "Reset/WB regression did not reach empty retained modules with a 4000K overlay.")
        let count = store.history.count
        let accepted = try await store.resetAsShotWhiteBalance()
        await store.waitForRender()
        guard let resetFrame = store.preview else { throw WorkflowFailure("Post-reset As Shot did not render.") }
        try requireWorkflow(accepted && store.currentEdits.temperature == nil && store.tint == 0,
                            "As Shot after Reset failed to replace the custom overlay.")
        try requireWorkflow(try ImageEvidence(url: resetFrame.imageURL).pixelDigest == baseline.pixelDigest,
                            "As Shot after Reset failed to restore actual camera white-balance pixels.")
        try requireWorkflow(store.history.count == count + 1, "Post-reset As Shot did not create exactly one entry.")
        store.undo()
        try requireWorkflow(store.currentEdits == custom, "Post-reset WB undo lost its complete overlay state.")
        store.restoreHistory(startingIndex)
        await store.waitForRender()
        try requireWorkflow(store.currentEdits == startingEdits, "Regression cleanup lost its starting complete edits.")
        print("PASS Reset Adjustments to 4000K to camera As Shot with real pixel restoration and exact undo")
    }
}
