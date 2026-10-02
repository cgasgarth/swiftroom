#if MASK_INSPECTOR_INTEGRATION
    import CryptoKit
    import Foundation

    private struct MaskOpaqueFailure: Error {
        let message: String
    }

    @MainActor
    enum MaskOpaqueWorkflow {
        static func execute(fixture: URL, xmp: URL) async throws {
            let root = URL(fileURLWithPath: "/tmp/swiftroom-mask-opaque-integration")
                .appendingPathComponent(UUID().uuidString)
            let originalHash = try digest(fixture)
            let store = try await seededStore(fixture: fixture, xmp: xmp, root: root)
            let model = MaskInspectorModel(store: store)
            model.activate()
            await model.waitForLoad()
            guard
                let opaque = model.state?.forms.first(where: { $0.geometry == nil && !$0.pointData.isEmpty })
            else { throw MaskOpaqueFailure(message: "Real opaque geometry did not load.") }
            model.chooseForm(opaque.id)
            try check(
                model.draftGeometry == nil && !model.hasChanges, "Opaque geometry created an editable draft.")
            model.setGeometry(
                .circle(
                    CircleMask(
                        center: MaskPoint(horizontal: 0.5, vertical: 0.5),
                        radius: 0.2, feather: 0.03)))
            try check(model.draftGeometry == nil, "Unsupported geometry accepted numeric replacement.")
            let otherForms = model.state?.forms.filter { $0.id != opaque.id }
            model.draftName = "Retained opaque geometry"
            model.apply()
            await model.waitForApply()
            try preserve(opaque, in: model)
            try check(
                model.state?.forms.filter { $0.id != opaque.id } == otherForms,
                "Name-only edit changed another form.")
            model.add(.circle)
            await model.waitForApply()
            try preserve(opaque, in: model)
            try store.saveCatalog()
            let reopened = try EditorStore(engine: store.engine, catalogURL: store.catalogURL)
            let reopenedModel = MaskInspectorModel(store: reopened)
            reopenedModel.activate()
            await reopenedModel.waitForLoad()
            try preserve(opaque, in: reopenedModel)
            try check(try digest(fixture) == originalHash, "Opaque workflow changed input RAW.")
            guard let document = store.selectedDocument else {
                throw MaskOpaqueFailure(message: "Opaque workflow lost its copied document.")
            }
            let copied = try CatalogRepository(rootURL: store.catalogURL).sourceURL(for: document)
            try check(try digest(copied) == originalHash, "Opaque workflow changed catalog original.")
            model.cancel()
            reopenedModel.cancel()
            print("MASK OPAQUE INSPECTOR INTEGRATION PASS \(root.path)")
        }

        private static func seededStore(fixture: URL, xmp: URL, root: URL) async throws -> EditorStore {
            let catalogURL = root.appendingPathComponent("Catalog")
            let repository = CatalogRepository(rootURL: catalogURL)
            let id = UUID()
            let relative = try repository.copyOriginal(from: fixture, id: id)
            let engine = NativePhotoEngineFactory.make(cacheDirectory: root.appendingPathComponent("Cache"))
            let prepared = try await engine.prepare(
                sourceURL: catalogURL.appendingPathComponent(relative),
                edits: EditState(darktableXMP: Data(contentsOf: xmp)))
            let document = PhotoDocument(
                id: id, fileName: fixture.lastPathComponent,
                originalSourcePath: fixture.path, relativeOriginalPath: relative,
                metadata: prepared.metadata, edits: prepared.edits,
                history: [HistoryEntry(label: "Seeded original", edits: prepared.edits)],
                historyIndex: 0, savedEdits: prepared.edits)
            try repository.save(PhotoCatalog(documents: [document], selectedAssetID: id))
            return try EditorStore(engine: engine, catalogURL: catalogURL)
        }

        private static func preserve(_ original: MaskForm, in model: MaskInspectorModel) throws {
            guard let retained = model.state?.forms.first(where: { $0.id == original.id }) else {
                throw MaskOpaqueFailure(
                    message: "Inspector edit dropped opaque geometry: \(model.errorMessage ?? "unknown")")
            }
            try check(
                retained.geometry == nil && retained.type == original.type
                    && retained.version == original.version
                    && retained.source == original.source && retained.pointData == original.pointData,
                "Inspector edit changed opaque geometry/source/point bytes.")
        }

        private static func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw MaskOpaqueFailure(message: message) }
        }
        private static func digest(_ url: URL) throws -> Data {
            Data(SHA256.hash(data: try Data(contentsOf: url)))
        }
    }
#endif
