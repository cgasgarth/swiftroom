import Foundation

@MainActor
enum ModuleEditingWorkflow {
    static func verify(store: EditorStore) async throws {
        let startingHistory = store.selectedDocument?.historyIndex ?? 0
        try await liveGesture(store: store)
        try await cancelledAndStale(store: store)
        store.restoreHistory(startingHistory)
        await store.waitForRender()
        try await asShot(store: store)
        store.restoreHistory(startingHistory)
        await store.waitForRender()
    }

    private static func liveGesture(store: EditorStore) async throws {
        guard let assetID = store.selectedAssetID, let frame = store.preview, let document = store.selectedDocument,
              let module = store.currentEdits.modules.first(where: { $0.operation == "exposure" }) else {
            throw WorkflowFailure("Missing real exposure state for live gesture.")
        }
        let baseline = store.currentEdits
        let baselineImage = try ImageEvidence(url: frame.imageURL)
        let source = try CatalogRepository(rootURL: store.catalogURL).sourceURL(for: document)
        let effective = try await store.engine.prepare(sourceURL: source, edits: baseline).edits
        guard let exposure = effective.modules.first(where: { $0.operation == module.operation }),
              let value = try await store.engine.parameters(for: exposure)["exposure"]?.doubleValue,
              let editingID = store.beginCurrentModuleEditing(assetID: assetID, catalogID: store.catalogID,
                expectedEdits: baseline, moduleID: module.id, label: "Live exposure") else {
            throw WorkflowFailure("Could not start a real module gesture.")
        }
        let count = store.history.count
        let retainedCount = (store.selectedDocument?.historyIndex ?? 0) + 1
        let first = try await store.previewCurrentModule(editingID: editingID, module: module,
            values: ["exposure": .number(value + 0.25)])
        try requireWorkflow(first, "First live module preview was rejected.")
        await store.waitForRender()
        try requireWorkflow(store.history.count == count, "Live preview committed history before release.")
        guard let live = store.preview else { throw WorkflowFailure("Live gesture did not render.") }
        try requireWorkflow(try ImageEvidence(url: live.imageURL).pixelDigest != baselineImage.pixelDigest,
            "Slider did not change real RAW pixels while its gesture remained open.")
        let second = try await store.previewCurrentModule(editingID: editingID, module: module,
            values: ["exposure": .number(value + 0.75)])
        try requireWorkflow(second, "Second live module preview was rejected.")
        await store.waitForRender()
        guard let finalModule = store.currentEdits.modules.first(where: { $0.id == module.id }),
              let finalFrame = store.preview else { throw WorkflowFailure("Missing final gesture state.") }
        let actual = try await store.engine.parameters(for: finalModule)["exposure"]?.doubleValue ?? .infinity
        try requireWorkflow(abs(actual - value - 0.75) < 0.000_001, "Preview compounded changes across drag samples.")
        let final = store.currentEdits
        let finalImage = try ImageEvidence(url: finalFrame.imageURL)
        store.endCurrentModuleEditing(editingID)
        try requireWorkflow(store.history.count == retainedCount + 1 && !store.canRedo,
                            "Live gesture did not append one entry and discard the old redo branch.")
        store.undo()
        await store.waitForRender()
        try requireWorkflow(store.currentEdits == baseline, "Module gesture undo lost complete baseline state.")
        guard let undo = store.preview else { throw WorkflowFailure("Gesture undo did not render.") }
        try requireWorkflow(try ImageEvidence(url: undo.imageURL).pixelDigest == baselineImage.pixelDigest,
                            "Module gesture undo changed baseline pixels.")
        store.redo()
        await store.waitForRender()
        try requireWorkflow(store.currentEdits == final, "Module gesture redo lost the complete final state.")
        guard let redo = store.preview else { throw WorkflowFailure("Gesture redo did not render.") }
        try requireWorkflow(try ImageEvidence(url: redo.imageURL).pixelDigest == finalImage.pixelDigest,
                            "Module gesture redo changed final pixels.")
        print("PASS real RAW live module preview, noncompounding samples, one history entry, exact undo/redo")
    }

    private static func cancelledAndStale(store: EditorStore) async throws {
        guard let assetID = store.selectedAssetID,
              let module = store.currentEdits.modules.first(where: { $0.operation == "exposure" }) else {
            throw WorkflowFailure("Missing exposure state for cancellation.")
        }
        let baseline = store.currentEdits
        let history = store.history
        guard let editingID = store.beginCurrentModuleEditing(assetID: assetID, catalogID: store.catalogID,
            expectedEdits: baseline, moduleID: module.id, label: "Cancelled exposure") else {
            throw WorkflowFailure("Could not start cancellation gesture.")
        }
        _ = try await store.previewCurrentModule(editingID: editingID, module: module,
                                               values: ["exposure": .number(2.25)])
        store.cancelCurrentModuleEditing(editingID)
        await store.waitForRender()
        try requireWorkflow(store.currentEdits == baseline && store.history == history,
                            "Cancellation changed complete state or committed history.")
        guard let staleID = store.beginCurrentModuleEditing(assetID: assetID, catalogID: store.catalogID,
            expectedEdits: baseline, moduleID: module.id, label: "Stale exposure"),
              let other = store.documents.first(where: { $0.id != assetID }) else {
            throw WorkflowFailure("Missing second photo for stale module preview.")
        }
        let pending = Task {
            try await store.previewCurrentModule(editingID: staleID, module: module,
                                                 values: ["exposure": .number(3.25)])
        }
        for _ in 0..<1000 {
            if store.isUpdatingEdits { break }
            await Task.yield()
        }
        try requireWorkflow(store.isUpdatingEdits, "Stale test did not start real adjustment work.")
        try requireWorkflow(!store.prepareToClose(.save), "Closing did not block pending adjustment work.")
        store.selectAsset(other.id)
        do {
            let accepted = try await pending.value
            try requireWorkflow(!accepted, "Stale module request was accepted.")
        } catch is CancellationError { }
        await store.waitForRender()
        try requireWorkflow(store.selectedAssetID == other.id && store.currentEdits == other.edits,
                            "Retired module gesture replaced another photo.")
        store.selectAsset(assetID)
        await store.waitForRender()
        try requireWorkflow(store.currentEdits == baseline && store.history == history,
                            "Retired module gesture resurrected edits in its original photo.")
        print("PASS module gesture cancellation and active stale-response rejection across photo switching")
    }

    private static func asShot(store: EditorStore) async throws {
        guard let frame = store.preview else { throw WorkflowFailure("Missing as-shot baseline preview.") }
        let baselineImage = try ImageEvidence(url: frame.imageURL)
        store.setTemperature(4000)
        await store.waitForRender()
        guard let quickFrame = store.preview,
              var unrelated = store.currentEdits.modules.first(where: { $0.operation == "exposure" }),
              let assetID = store.selectedAssetID else { throw WorkflowFailure("Missing WB folding state.") }
        let quickImage = try ImageEvidence(url: quickFrame.imageURL)
        try requireWorkflow(quickImage.pixelDigest != baselineImage.pixelDigest, "4000K did not alter real RAW pixels.")
        unrelated.name = "WB folding gate"
        let committed = try await store.commitCurrentModule(assetID: assetID, catalogID: store.catalogID,
            expectedEdits: store.currentEdits, module: unrelated, values: [:], label: "Fold white balance")
        try requireWorkflow(committed, "Unrelated advanced commit did not fold quick white balance.")
        await store.waitForRender()
        let folded = store.currentEdits
        try requireWorkflow(folded.temperature == nil, "Folded WB retained a quick overlay.")
        let count = store.history.count
        let restored = try await store.resetAsShotWhiteBalance()
        try requireWorkflow(restored, "As-shot reset was rejected.")
        await store.waitForRender()
        guard let reset = store.preview else { throw WorkflowFailure("As-shot reset did not render.") }
        try requireWorkflow(try ImageEvidence(url: reset.imageURL).pixelDigest == baselineImage.pixelDigest,
                            "As-shot reset after an unrelated advanced commit did not restore camera RAW pixels.")
        try requireWorkflow(store.history.count == count + 1, "As-shot reset did not create one history entry.")
        try requireWorkflow(store.currentEdits.darktableXMP == folded.darktableXMP,
                            "As-shot reset discarded full XMP.")
        try requireWorkflow(store.currentEdits.modules.filter { $0.operation != "temperature" }
                            == folded.modules.filter { $0.operation != "temperature" },
                            "As-shot reset changed unrelated opaque module state.")
        print("PASS camera as-shot WB after quick 4000K folded into module state; full XMP/other modules retained")
    }
}
