#if ADVANCED_MODULE_INTEGRATION
    import CryptoKit
    import Darwin
    import Foundation
    import ImageIO

    private struct AdvancedWorkflowFailure: Error {
        let message: String
    }

    @main
    enum AdvancedModuleWorkflow {
        @MainActor
        static func main() async {
            do { try await execute() } catch {
                FileHandle.standardError.write(Data("ADVANCED INTEGRATION FAIL: \(error)\n".utf8))
                exit(1)
            }
        }

        @MainActor
        private static func execute() async throws {
            guard let fixturePath = CommandLine.arguments.dropFirst().first else {
                throw AdvancedWorkflowFailure(message: "Provide a copied RAW fixture path.")
            }
            let fixture = URL(fileURLWithPath: fixturePath)
            let root = URL(fileURLWithPath: "/tmp/swiftroom-advanced-integration")
                .appendingPathComponent(UUID().uuidString)
            let catalogURL = root.appendingPathComponent("Catalog")
            let engine = NativePhotoEngineFactory.make(
                cacheDirectory: catalogURL.appendingPathComponent("Cache"))
            let store = try EditorStore(engine: engine, catalogURL: catalogURL)
            let originalHash = try digest(fixture)
            await store.importURLs([fixture])
            await store.waitForRender()
            guard let document = store.selectedDocument, let baseline = store.preview else {
                throw AdvancedWorkflowFailure(
                    message: "Real RAW import/render failed: \(store.errorMessage ?? "unknown")")
            }
            let baselineDigest = try pixels(baseline.imageURL)
            let editor = AdvancedModuleEditor(store: store)
            editor.activate()
            await editor.waitForLoad()
            editor.chooseOperation("exposure")
            await editor.waitForLoad()
            try await verifyExposure(
                editor: editor, store: store, document: document, baselineDigest: baselineDigest)
            try await persistence(editor: editor, store: store, baselineDigest: baselineDigest)
            try await options(editor: editor, store: store, engine: engine)
            try await integerEntry(editor: editor, store: store)
            try await switching(editor: editor, store: store, fixture: fixture, firstID: document.id)
            try require(try digest(fixture) == originalHash, "Input RAW was modified.")
            let copied = try CatalogRepository(rootURL: catalogURL).sourceURL(for: document)
            try require(try digest(copied) == originalHash, "Copied catalog original was modified.")
            print("ADVANCED INTEGRATION PASS \(root.path)")
        }

        @MainActor
        private static func verifyExposure(
            editor: AdvancedModuleEditor, store: EditorStore,
            document: PhotoDocument, baselineDigest: String
        ) async throws {
            guard let schema = editor.schema,
                let originalModule = store.currentEdits.modules.first(where: {
                    $0.id == editor.selectedModuleID
                }),
                let exposureField = schema.fields.first(where: { $0.name == "exposure" }),
                let originalEV = editor.values["exposure"]?.doubleValue
            else {
                throw AdvancedWorkflowFailure(
                    message: "Real exposure schema or values unavailable: \(editor.errorMessage ?? "unknown")"
                )
            }
            try require(
                editor.canEdit && !editor.hasChanges, "Decoded current values created a false dirty draft.")
            let target = originalEV + 0.75
            guard let preciseValue = exposureField.parsedValue(String(target)) else {
                throw AdvancedWorkflowFailure(message: "Exact exposure entry rejected real schema bounds.")
            }
            editor.setValue("exposure", value: preciseValue)
            editor.setValidity("exposure", valid: false)
            try require(!editor.canApply, "Invalid numeric draft allowed Apply.")
            editor.setValidity("exposure", valid: true)
            try require(editor.canApply, "Valid numeric draft did not allow Apply.")
            let historyCount = store.history.count
            editor.apply()
            await editor.waitForApply()
            await editor.waitForLoad()
            await store.waitForRender()
            guard let changed = store.currentEdits.modules.first(where: { $0.id == originalModule.id }),
                let changedPreview = store.preview
            else {
                throw AdvancedWorkflowFailure(message: "Applied exposure produced no module/preview.")
            }
            let expected = try await store.engine.updating(
                module: originalModule, values: ["exposure": preciseValue])
            try require(changed == expected, "Atomic commit changed unrelated module data.")
            try require(store.history.count == historyCount + 1, "Module draft was not one history entry.")
            try require(
                store.currentEdits.darktableXMP == document.edits.darktableXMP, "Unrelated XMP changed.")
            try require(
                store.currentEdits.modules.filter { $0.id != changed.id }
                    == document.edits.modules.filter { $0.id != changed.id }, "Other module state changed.")
            let changedValues = try await store.engine.parameters(for: changed)
            try require(
                abs((changedValues["exposure"]?.doubleValue ?? .infinity) - target) < 0.000_001,
                "Exact entry did not roundtrip through native float storage.")
            let changedDigest = try pixels(changedPreview.imageURL)
            try require(baselineDigest != changedDigest, "Advanced exposure left real RAW pixels unchanged.")
            let actual = changedValues["exposure"]?.entryText ?? "missing"
            print("PASS real schema/decode/exact-entry/encode/render: exposure \(originalEV) -> \(actual)")
            print("PASS one history entry, unrelated module/blend/order/instance data and full XMP preserved")
        }

        @MainActor
        private static func persistence(
            editor: AdvancedModuleEditor, store: EditorStore,
            baselineDigest: String
        ) async throws {
            store.undo()
            await store.waitForRender()
            guard let undoPreview = store.preview else {
                throw AdvancedWorkflowFailure(message: "Undo render failed.")
            }
            try require(
                try pixels(undoPreview.imageURL) == baselineDigest,
                "Undo did not restore real baseline pixels.")
            store.redo()
            await store.waitForRender()
            editor.synchronize()
            await editor.waitForLoad()
            try require(!editor.hasChanges, "External history navigation left a stale draft.")
            try store.saveCatalog()
            let reopened = try EditorStore(engine: store.engine, catalogURL: store.catalogURL)
            try require(reopened.currentEdits == store.currentEdits, "Save/reopen changed advanced state.")
            print("PASS pixel-exact undo, redo and full-state save/reopen")

        }

    }

    extension AdvancedModuleWorkflow {
        @MainActor
        private static func options(
            editor: AdvancedModuleEditor, store: EditorStore, engine: any PhotoEngine
        ) async throws {
            guard let schema = editor.schema else {
                throw AdvancedWorkflowFailure(message: "Missing options schema.")
            }
            let enumFields = schema.fields.filter { $0.kind == .enumeration }
            let boolFields = schema.fields.filter { $0.kind == .bool }
            guard let enumField = enumFields.first, let choice = enumField.choices.first,
                let boolField = boolFields.first, case .boolean(let current) = editor.values[boolField.name]
            else {
                throw AdvancedWorkflowFailure(message: "Real exposure did not expose enum/bool controls.")
            }
            editor.setValue(enumField.name, value: .integer(choice.value))
            editor.setValue(boolField.name, value: .boolean(!current))
            editor.draftName = "Advanced integration"
            editor.apply()
            await editor.waitForApply()
            await editor.waitForLoad()
            guard let module = store.currentEdits.modules.first(where: { $0.id == editor.selectedModuleID })
            else {
                throw AdvancedWorkflowFailure(message: "Option apply lost module identity.")
            }
            let decoded = try await engine.parameters(for: module)
            try require(
                enumField.choiceValue(for: decoded[enumField.name] ?? .text("")) == choice.value,
                "Enum selection did not roundtrip to a declared choice.")
            try require(decoded[boolField.name] == .boolean(!current), "Boolean selection did not roundtrip.")
            try require(module.name == "Advanced integration", "Instance label did not apply.")
            editor.draftEnabled.toggle()
            let enabled = editor.draftEnabled
            editor.apply()
            await editor.waitForApply()
            await editor.waitForLoad()
            try require(
                store.currentEdits.modules.first { $0.id == module.id }?.enabled == enabled,
                "Enabled state did not apply.")
            editor.resetDefaults()
            for field in editor.resettableFields {
                guard let actual = editor.values[field.name], let value = field.defaultValue else { continue }
                try require(field.valuesEqual(actual, value), "Reset ignored a supported default.")
            }
            editor.discard()
            try require(!editor.hasChanges, "Discard did not restore committed parameters.")
            print(
                "PASS enum symbols/choice integers, booleans, instance label, enabled state and supported defaults"
            )
        }

        @MainActor
        private static func integerEntry(editor: AdvancedModuleEditor, store: EditorStore) async throws {
            editor.chooseOperation("rawprepare")
            await editor.waitForLoad()
            guard let field = editor.schema?.fields.first(where: { $0.name == "left" }),
                case .integer(let previous) = editor.values[field.name],
                let module = store.currentEdits.modules.first(where: { $0.id == editor.selectedModuleID }),
                let value = field.parsedValue(String(previous + 2)) else {
                throw AdvancedWorkflowFailure(message: "Real rawprepare integer field unavailable.")
            }
            try require(field.parsedValue("2.5") == nil, "Integer entry accepted a fractional value.")
            editor.setValue(field.name, value: value)
            editor.apply()
            await editor.waitForApply()
            await editor.waitForLoad()
            await store.waitForRender()
            guard let updated = store.currentEdits.modules.first(where: { $0.id == module.id }) else {
                throw AdvancedWorkflowFailure(message: "Integer apply lost module identity.")
            }
            let actual = try await store.engine.parameters(for: updated)
            try require(actual[field.name] == value, "Exact integer entry did not roundtrip.")
            let expected = try await store.engine.updating(module: module, values: [field.name: value])
            try require(updated == expected, "Integer entry changed unknown compound parameters.")
            try require(store.errorMessage == nil, "Integer edit did not render: \(store.errorMessage ?? "")")
            store.undo()
            await store.waitForRender()
            editor.synchronize()
            await editor.waitForLoad()
            print("PASS real integer entry, fractional rejection, full blob preservation and rendering")
        }

        @MainActor
        private static func switching(
            editor: AdvancedModuleEditor, store: EditorStore, fixture: URL, firstID: UUID
        ) async throws {
            await store.importURLs([fixture])
            guard let secondID = store.selectedAssetID, secondID != firstID else {
                throw AdvancedWorkflowFailure(message: "Second real RAW import failed.")
            }
            let secondEdits = store.currentEdits
            store.selectAsset(firstID)
            editor.activate()
            await editor.waitForLoad()
            editor.chooseOperation("exposure")
            await editor.waitForLoad()
            editor.setValue("exposure", value: .number(1.23456789))
            editor.apply()
            await Task.yield()
            store.selectAsset(secondID)
            editor.activate()
            await editor.waitForApply()
            await editor.waitForLoad()
            await store.waitForRender()
            try require(store.currentEdits == secondEdits, "Stale async module edit affected another photo.")
            try require(store.preview?.assetID == secondID, "Stale module render affected another photo.")
            try await returnSwitch(editor: editor, store: store, firstID: firstID, secondID: secondID)
            editor.chooseOperation("tonecurve")
            await Task.yield()
            editor.chooseOperation("exposure")
            await editor.waitForLoad()
            try require(
                editor.selectedOperation == "exposure" && editor.schema?.operation == "exposure",
                "Stale schema replaced the selected operation.")
            editor.cancel()
            print("PASS cancelled apply on image switch and stale schema suppression")
        }

        @MainActor
        private static func returnSwitch(
            editor: AdvancedModuleEditor, store: EditorStore, firstID: UUID, secondID: UUID
        ) async throws {
            store.selectAsset(firstID)
            editor.activate()
            await editor.waitForLoad()
            let expected = store.currentEdits
            editor.setValue("exposure", value: .number(1.987654))
            editor.apply()
            await Task.yield()
            store.selectAsset(secondID)
            store.selectAsset(firstID)
            await editor.waitForApply()
            await editor.waitForLoad()
            await store.waitForRender()
            try require(store.currentEdits == expected, "Stale A/B/A edit bypassed the generation guard.")
            print("PASS stale Apply rejected after A/B/A returns to identical document state")
        }

        private static func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw AdvancedWorkflowFailure(message: message) }
        }

        private static func digest(_ url: URL) throws -> String {
            SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }

        private static func pixels(_ url: URL) throws -> String {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                let data = image.dataProvider?.data
            else {
                throw AdvancedWorkflowFailure(message: "Cannot decode real developed pixels.")
            }
            return SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined()
        }
    }
#endif
