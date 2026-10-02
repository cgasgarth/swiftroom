import Foundation

@MainActor
enum SafetyWorkflow {
    static func verify(store: EditorStore, fixture: URL, output: URL) async throws {
        try closing(store: store, output: output)
        try await protectedCatalog(store: store, output: output)
        try await linkedImport(store: store, fixture: fixture, output: output)
    }

    private static func closing(store: EditorStore, output: URL) throws {
        store.setExposure(0.24)
        let documents = store.documents
        let catalog = store.catalogURL.appendingPathComponent("catalog.json")
        let backup = output.appendingPathComponent("catalog-before-save.json")
        let savedDigest = try fileDigest(catalog)
        try requireWorkflow(!store.prepareToClose(.cancel), "Cancel allowed closing an edited catalog.")
        try FileManager.default.moveItem(at: catalog, to: backup)
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: false)
        do {
            defer {
                try? FileManager.default.removeItem(at: catalog)
                try? FileManager.default.moveItem(at: backup, to: catalog)
            }
            try requireWorkflow(!store.prepareToClose(.save), "Failed save allowed closing an edited catalog.")
            try requireWorkflow(store.hasUnsavedChanges && store.documents == documents,
                                "Failed close save cleared or changed live edits/history.")
            try requireWorkflow(store.errorMessage != nil, "Failed close save did not report an error.")
            try requireWorkflow(try fileDigest(backup) == savedDigest, "Failed save changed the prior catalog.")
        }
        try requireWorkflow(store.prepareToClose(.save), "Successful save did not permit closing.")
        let reloaded = try CatalogRepository(rootURL: store.catalogURL).load()
        try requireWorkflow(!store.hasUnsavedChanges && reloaded.documents == store.documents,
                            "Successful close save lost complete documents/history.")
        store.setTint(2)
        let dirty = store.documents
        try requireWorkflow(store.prepareToClose(.discard) && store.documents == dirty && store.hasUnsavedChanges,
                            "Discard decision prematurely mutated the live document.")
        store.undo()
        store.clearError()
        print("PASS closing cancellation, failed-save blocking with full state retained, successful durable close save")
    }

    private static func protectedCatalog(store: EditorStore, output: URL) async throws {
        guard let document = store.selectedDocument else { throw WorkflowFailure("No photo for protected export.") }
        let catalog = store.catalogURL.appendingPathComponent("catalog.json")
        let symbolic = output.appendingPathComponent("catalog-alias.png")
        let hard = output.appendingPathComponent("catalog-hardlink.png")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: catalog)
        try FileManager.default.linkItem(at: catalog, to: hard)
        let before = try fileDigest(catalog)
        let documents = store.documents
        for destination in [catalog, symbolic, hard] {
            let authorization = try ExportOverwriteAuthorization.capture(destination: destination)
            do {
                _ = try store.makeExportRequest(destination: destination, format: .png, colorSpace: .sRGB,
                    quality: 0.95, maximumDimension: 1600, overwriteAuthorization: authorization)
                throw WorkflowFailure("An authorized catalog alias was accepted as an image export destination.")
            } catch PhotoEngineError.unsupported { }
            let request = ExportRequest(assetID: document.id,
                sourceURL: try CatalogRepository(rootURL: store.catalogURL).sourceURL(for: document),
                edits: document.edits, destinationURL: destination, format: .png, colorSpace: .sRGB,
                quality: 0.95, maximumDimension: 1600, overwriteAuthorization: authorization)
            do {
                _ = try await store.export(request)
                throw WorkflowFailure("Direct store export bypassed catalog alias protection.")
            } catch PhotoEngineError.unsupported { }
        }
        try requireWorkflow(try fileDigest(catalog) == before && store.documents == documents,
                            "Rejected catalog exports changed saved or live state.")
        print("PASS authorized export replacement rejects live catalog, symlink, and hard-link aliases")
    }

    private static func linkedImport(store: EditorStore, fixture: URL, output: URL) async throws {
        guard let data = store.currentEdits.darktableXMP else { throw WorkflowFailure("Missing full import XMP.") }
        let catalog = output.appendingPathComponent("LinkedOnlyCatalog")
        let linkedEngine = NativePhotoEngineFactory.make(cacheDirectory: catalog.appendingPathComponent("Cache"))
        let store = try EditorStore(engine: linkedEngine, catalogURL: catalog)
        let folder = output.appendingPathComponent("LinkedInput")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let symbolic = folder.appendingPathComponent("linked." + fixture.pathExtension)
        let xmp = folder.appendingPathComponent("original.xmp")
        try data.write(to: xmp)
        let symbolicXMP = URL(fileURLWithPath: symbolic.path + ".xmp")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: fixture)
        try FileManager.default.createSymbolicLink(at: symbolicXMP, withDestinationURL: xmp)
        let count = store.documents.count
        await store.importURLs([symbolic])
        await store.waitForRender()
        guard store.documents.count == count + 1, let document = store.selectedDocument else {
            throw WorkflowFailure("Symlink RAW import failed: \(store.errorMessage ?? "unknown")")
        }
        let repository = CatalogRepository(rootURL: store.catalogURL)
        let copy = try repository.sourceURL(for: document)
        let copyXMP = URL(fileURLWithPath: copy.path + ".xmp")
        for item in [copy, copyXMP] {
            let attributes = try FileManager.default.attributesOfItem(atPath: item.path)
            try requireWorkflow(attributes[.type] as? FileAttributeType == .typeRegular,
                                "Imported RAW or XMP remained an external symlink.")
        }
        try requireWorkflow(try fileDigest(copy) == fileDigest(fixture), "Symlink import changed RAW bytes.")
        try requireWorkflow(try Data(contentsOf: copyXMP) == data, "Symlink XMP copy lost full bytes.")
        try FileManager.default.removeItem(at: symbolic)
        try FileManager.default.removeItem(at: symbolicXMP)
        try protectLinkedOriginal(store: store, document: document, fixture: fixture, sidecar: xmp)
        try FileManager.default.removeItem(at: xmp)
        store.retryRender()
        await store.waitForRender()
        try requireWorkflow(store.preview?.assetID == document.id, "Removing input aliases broke the catalog copy.")
        let external = copy.deletingLastPathComponent().appendingPathComponent("external." + fixture.pathExtension)
        try FileManager.default.createSymbolicLink(at: external, withDestinationURL: fixture)
        var unsafe = document
        unsafe.relativeOriginalPath = document.relativeOriginalPath.replacingOccurrences(of: copy.lastPathComponent,
                                                                                       with: external.lastPathComponent)
        do {
            _ = try repository.sourceURL(for: unsafe)
            throw WorkflowFailure("An external-link original path was accepted from a catalog.")
        } catch CatalogError.invalid { }
        try FileManager.default.removeItem(at: external)
        print("PASS symlink RAW/adjacent XMP materialized as regular files; external catalog links rejected")
    }

    private static func protectLinkedOriginal(
        store: EditorStore, document: PhotoDocument, fixture: URL, sidecar: URL
    ) throws {
        try requireWorkflow(document.originalSourcePath == fixture.resolvingSymlinksInPath().standardizedFileURL.path,
                            "Linked import did not retain the resolved original source path.")
        let authorization = try ExportOverwriteAuthorization.capture(destination: fixture)
        do {
            _ = try store.makeExportRequest(destination: fixture, format: .png, colorSpace: .sRGB,
                quality: 0.95, maximumDimension: 1600, overwriteAuthorization: authorization)
            throw WorkflowFailure("Removing the import symlink allowed replacement of the source original.")
        } catch PhotoEngineError.unsupported { }
        try requireWorkflow(document.originalSidecarPath == sidecar.resolvingSymlinksInPath().standardizedFileURL.path,
                            "Linked import discarded the actual selected sidecar provenance.")
        let sidecarAuthorization = try ExportOverwriteAuthorization.capture(destination: sidecar)
        do {
            _ = try store.makeExportRequest(destination: sidecar, format: .png, colorSpace: .sRGB,
                quality: 0.95, maximumDimension: 1600, overwriteAuthorization: sidecarAuthorization)
            throw WorkflowFailure("Removing the sidecar alias allowed replacement of its separately named target.")
        } catch PhotoEngineError.unsupported { }
        for destination in [URL(fileURLWithPath: fixture.path + ".xmp"),
                            fixture.deletingPathExtension().appendingPathExtension("xmp")] {
            do {
                _ = try store.makeExportRequest(destination: destination, format: .png, colorSpace: .sRGB,
                    quality: 0.95, maximumDimension: 1600)
                throw WorkflowFailure("Export accepted an original-sidecar location.")
            } catch PhotoEngineError.unsupported { }
        }
        print("PASS removed import aliases retain original and adjacent-sidecar export protection")
    }
}
