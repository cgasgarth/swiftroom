#if LIBRARY_INTEGRATION
import CryptoKit
import Foundation

@main
enum LibraryWorkflow {
    @MainActor
    static func main() async {
        do {
            guard let path = ProcessInfo.processInfo.environment["NATIVE_PHOTO_FIXTURE"] else {
                throw LibraryWorkflowFailure(message: "Provide a copied RAW via NATIVE_PHOTO_FIXTURE.")
            }
            let fixture = URL(fileURLWithPath: path)
            let sourceDigest = try digest(fixture)
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("swiftroom-library-\(UUID().uuidString)", isDirectory: true)
            let catalogURL = root.appendingPathComponent("Catalog", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let sources = try ["alpha", "bravo", "charlie"].map { name in
                let source = root.appendingPathComponent(name).appendingPathExtension(fixture.pathExtension)
                try FileManager.default.copyItem(at: fixture, to: source)
                return source
            }
            let engine = NativePhotoEngineFactory.make(cacheDirectory: catalogURL.appendingPathComponent("Cache"))
            let store = try EditorStore(engine: engine, catalogURL: catalogURL)
            try await verifyImportIsolation(store: store, sources: sources, root: root)
            await store.waitForRender()
            try require(store.documents.count == 3, "Real RAW import failed: \(store.errorMessage ?? "unknown error")")
            try require(store.preview != nil, "Real engine did not develop the imported RAW.")
            let model = LibraryController(store: store)
            let ids = model.visibleDocuments.map(\.id)
            try require(ids.count == 3, "Library omitted imported photos.")
            try await verifySwitching(model: model, ids: ids)
            try verifySelection(model: model, ids: ids)
            try verifyFiltering(model: model, ids: ids)
            try verifyCollections(model: model, ids: ids)
            try await verifyPersistence(model: model, engine: engine)
            try require(try digest(fixture) == sourceDigest, "The source RAW changed.")
            for source in sources {
                try require(try digest(source) == sourceDigest, "A local test source changed.")
            }
            for document in store.documents {
                let copied = try CatalogRepository(rootURL: catalogURL).sourceURL(for: document)
                try require(try digest(copied) == sourceDigest, "A catalog original changed.")
            }
            print("PASS source and catalog original SHA256 unchanged")
            print("LIBRARY INTEGRATION PASS \(root.path)")
        } catch {
            FileHandle.standardError.write(Data("LIBRARY INTEGRATION FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func verifyImportIsolation(store: EditorStore, sources: [URL], root: URL) async throws {
        let originalCatalogURL = store.catalogURL
        let importing = Task { await store.importURLs(sources) }
        await Task.yield()
        let observedImport = store.isImporting
        var switchWasBlocked = false
        if observedImport {
            do {
                try store.openCatalog(at: root.appendingPathComponent("DuringImport"))
            } catch {
                switchWasBlocked = true
            }
        }
        await importing.value
        try require(observedImport, "The test did not observe asynchronous import.")
        try require(switchWasBlocked, "Direct catalog switching was allowed while RAW copies were importing.")
        try require(store.catalogURL == originalCatalogURL, "Import crossed catalog repositories.")
        print("PASS direct catalog-switch guard during real asynchronous RAW import")
    }

    @MainActor
    private static func verifySwitching(model: LibraryController, ids: [UUID]) async throws {
        let store = model.store
        model.select([ids[0]])
        let historyCount = store.history.count
        store.beginEditing("Exposure")
        store.setExposure(0.5)
        model.select([ids[1], ids[2]], preferredID: ids[1])
        let first = store.documents.first { $0.id == ids[0] }
        try require(first?.edits.exposureEV == 0.5, "Switching lost the pending exposure.")
        try require(first?.history.count == historyCount + 1, "Switching did not commit one gesture history entry.")
        try require(model.selectedIDs == [ids[1], ids[2]],
            "Multi-selection was reduced while opening the active photo.")
        model.select([ids[0]])
        await store.waitForRender()
        try require(store.preview?.assetID == ids[0], "The displayed preview belongs to another photo.")
        try require(store.currentEdits.exposureEV == 0.5, "Returning to the photo lost edits.")
        print("PASS real RAW preview, switching, pending gesture history and retained edits")
    }

    @MainActor
    private static func verifySelection(model: LibraryController, ids: [UUID]) throws {
        model.select([ids[0]])
        model.select(Set(ids))
        try require(model.store.selectedAssetID == ids[2],
            "Native range selection did not activate the range endpoint.")
        model.select([ids[0], ids[1]])
        try require(model.store.selectedAssetID == ids[1],
            "Shrinking native selection did not activate its endpoint.")
        model.select([ids[0]])
        model.moveSelection(1, extending: true)
        try require(model.selectedIDs == [ids[0], ids[1]], "Shift movement did not extend the range.")
        model.moveSelection(1, extending: true)
        try require(model.selectedIDs == Set(ids), "Shift movement lost the range anchor.")
        model.moveSelection(-1, extending: true)
        try require(model.selectedIDs == [ids[0], ids[1]], "Shift movement did not shrink the range.")
        model.clearSelection()
        try require(model.selectedIDs.isEmpty && model.store.selectedAssetID == nil,
            "Cancel retained a selected photo.")
        try require(model.store.preview == nil && !model.store.isRendering, "Cancel retained preview/loading state.")
        model.synchronize()
        try require(model.selectedIDs.isEmpty, "Store synchronization undid the clear-selection action.")
        model.moveSelection(1)
        try require(model.selectedIDs == [ids[0]], "Keyboard navigation failed from empty selection.")
        model.selectAll()
        try require(model.selectedIDs == Set(ids), "Select All omitted visible photos.")
        print("PASS multi-selection, range extension/shrink, cancel and navigation")
    }

    @MainActor
    private static func verifyFiltering(model: LibraryController, ids: [UUID]) throws {
        model.setRating(4)
        try require(model.store.documents.allSatisfy { $0.rating == 4 }, "Batch rating omitted selected photos.")
        model.query.rating = .five
        try require(model.visibleDocuments.isEmpty && model.store.selectedAssetID == nil,
            "A hidden photo remained active after filtering.")
        model.query.rating = .three
        model.select([ids[0]])
        model.setRating(2)
        try require(!model.visibleDocuments.contains { $0.id == ids[0] },
            "Rating filter did not update after mutation.")
        try require(model.store.selectedAssetID != ids[0], "The newly hidden photo stayed active.")
        model.resetFilters()
        model.selectAll()
        model.toggleFavorites()
        model.query.scope = .favorites
        model.toggleFavorites(ids: Set(ids))
        try require(model.visibleDocuments.isEmpty && model.selectedIDs.isEmpty,
            "Removing favorites did not reconcile the favorite scope.")
        model.resetFilters()
        model.selectAll()
        model.toggleFavorites()
        model.query.hidesRejected = true
        model.select([ids[0]])
        model.toggleRejected()
        try require(model.visibleDocuments.count == 2 && model.store.selectedAssetID != ids[0],
            "Rejecting a photo did not update filtering and active selection.")
        model.query.hidesRejected = false
        model.query.scope = .rejected
        try require(model.visibleDocuments.map(\.id) == [ids[0]], "Rejected scope contains incorrect photos.")
        model.toggleRejected()
        try require(model.visibleDocuments.isEmpty && model.store.selectedAssetID == nil,
            "Unrejecting did not empty and clear the rejected scope.")
        model.resetFilters()
        model.query.search = "bravo"
        try require(model.visibleDocuments.map(\.id) == [ids[1]], "Filename search did not find the expected photo.")
        model.query.search = "BRAVO missing"
        try require(model.visibleDocuments.isEmpty, "Search tokens did not combine.")
        model.resetFilters()
        model.query.descending = true
        try require(model.visibleDocuments.map(\.id) == ids.reversed(), "Reverse filename sort is incorrect.")
        model.query.sort = .rating
        try require(model.visibleDocuments.last?.id == ids[0], "Rating sort is incorrect.")
        model.resetFilters()
        print("PASS live rating/favorite/rejection filters, hidden selection, search and stable sorting")
    }

    @MainActor
    private static func verifyCollections(model: LibraryController, ids: [UUID]) throws {
        model.selectAll()
        guard let collectionID = model.createCollection(name: "  Picks  ", addingSelection: true) else {
            throw LibraryWorkflowFailure(message: "Collection creation failed.")
        }
        try require(model.activeCollection?.name == "Picks", "The collection name was not trimmed.")
        try require(model.activeCollection?.assetIDs == Set(ids), "Collection creation omitted the selection.")
        try require(model.createCollection(name: "picks", addingSelection: false) == nil,
            "A duplicate collection name was accepted.")
        try require(model.createCollection(name: " \n ", addingSelection: false) == nil,
            "An empty collection name was accepted.")
        try require(model.renameCollection(collectionID, name: "Final Picks"), "Collection rename failed.")
        model.select([ids[1], ids[2]], preferredID: ids[1])
        model.removeFromCollection(collectionID, ids: [ids[1]])
        try require(model.selectedIDs == [ids[2]], "Collection removal discarded a still-visible selection.")
        model.removeFromCollection(collectionID, ids: [ids[2]])
        try require(model.visibleDocuments.map(\.id) == [ids[0]] && model.selectedIDs == [ids[0]],
            "Collection removal did not choose the remaining visible photo.")
        model.addToCollection(collectionID, ids: [ids[1], ids[2]])
        guard let emptyID = model.createCollection(name: "Empty", addingSelection: false) else {
            throw LibraryWorkflowFailure(message: "Empty collection creation failed.")
        }
        try require(model.visibleDocuments.isEmpty && model.store.selectedAssetID == nil,
            "An empty collection retained an active photo.")
        model.deleteCollection(emptyID)
        try require(model.query.scope == .all && model.store.documents.count == 3,
            "Deleting a collection changed catalog photos.")
        model.query.scope = .collection(collectionID)
        print("PASS collection create/rename/add/remove/delete, unique names and empty selection")
    }

    @MainActor
    private static func verifyPersistence(model: LibraryController, engine: any PhotoEngine) async throws {
        let store = model.store
        let edited = store.documents.first { $0.edits.exposureEV == 0.5 }
        try require(store.hasUnsavedChanges, "Library mutations were not marked dirty.")
        try store.saveCatalog()
        let reopened = try EditorStore(engine: engine, catalogURL: store.catalogURL)
        try require(reopened.library == store.library, "Save/reopen changed library metadata.")
        try require(reopened.documents == store.documents, "Save/reopen lost ratings, flags, edits or history.")
        try require(!reopened.hasUnsavedChanges, "Reopened catalog is dirty.")
        try require(reopened.selectedAssetID == store.selectedAssetID, "Save/reopen changed active selection.")
        if let edited {
            reopened.selectAsset(edited.id)
            try require(reopened.currentEdits == edited.edits, "Saved edits changed after selection.")
            try require(reopened.history == edited.history, "Saved gesture history changed after selection.")
            reopened.undo()
            try require(reopened.currentEdits.exposureEV == 0, "Library metadata operations damaged adjustment undo.")
            try require(reopened.library == store.library, "Adjustment undo changed library metadata.")
        }
        let alternateURL = store.catalogURL.deletingLastPathComponent().appendingPathComponent("Alternate")
        model.query.search = "alpha"
        model.select([store.documents[0].id])
        model.toggleFavorites()
        model.query.search = ""
        model.select([store.documents[1].id])
        try store.openCatalog(at: alternateURL)
        model.synchronize()
        try require(model.visibleDocuments.isEmpty && model.selectedIDs.isEmpty,
            "Opening another catalog retained selection.")
        try require(model.query == LibraryQuery(), "Opening another catalog retained old filters.")
        try store.openCatalog(at: reopened.catalogURL)
        model.synchronize()
        try require(store.documents.count == 3 && store.library != reopened.library,
            "Opening another catalog lost the unsaved library mutation.")
        let disk = try CatalogRepository(rootURL: reopened.catalogURL).load()
        try require(store.selectedAssetID == disk.selectedAssetID,
            "Library synchronization replaced the persisted active photo.")
        await store.waitForRender()
        print("PASS atomic save/reopen, flags/collections/history, adjustment undo and unsaved catalog switching")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw LibraryWorkflowFailure(message: message) }
    }

    private static func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct LibraryWorkflowFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
#endif
