#if MASK_INSPECTOR_INTEGRATION
    import CryptoKit
    import Darwin
    import Foundation
    import ImageIO

    private struct MaskWorkflowFailure: Error {
        let message: String
    }

    @main
    enum MaskInspectorWorkflow {
        @MainActor
        static func main() async {
            do { try await execute() } catch {
                FileHandle.standardError.write(Data("MASK INSPECTOR INTEGRATION FAIL: \(error)\n".utf8))
                exit(1)
            }
        }

        @MainActor
        private static func execute() async throws {
            if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--opaque" {
                try await MaskOpaqueWorkflow.execute(
                    fixture: URL(fileURLWithPath: CommandLine.arguments[2]),
                    xmp: URL(fileURLWithPath: CommandLine.arguments[3]))
                return
            }
            guard let path = CommandLine.arguments.dropFirst().first else {
                throw MaskWorkflowFailure(message: "Provide a copied RAW fixture path.")
            }
            let fixture = URL(fileURLWithPath: path)
            let root = URL(fileURLWithPath: "/tmp/swiftroom-mask-inspector-integration")
                .appendingPathComponent(UUID().uuidString)
            evidence("RUN \(root.path)")
            let catalogURL = root.appendingPathComponent("Catalog")
            let engine = NativePhotoEngineFactory.make(cacheDirectory: root.appendingPathComponent("Cache"))
            let store = try EditorStore(engine: engine, catalogURL: catalogURL)
            let originalHash = try digest(fixture)
            await store.importURLs([fixture])
            await store.waitForRender()
            guard let document = store.selectedDocument, store.preview != nil else {
                throw MaskWorkflowFailure(
                    message: "RAW import/render failed: \(store.errorMessage ?? "unknown")")
            }
            let model = MaskInspectorModel(store: store)
            model.activate()
            await model.waitForLoad()
            try require(model.canEdit && !model.hasChanges, "Real mask state did not load cleanly.")
            let circleID = try await shapes(model: model, store: store)
            try await ellipse(model: model)
            try await gradient(model: model)
            let groupID = try await grouping(model: model, store: store, circleID: circleID)
            try await blending(model: model, store: store, groupID: groupID)
            try await persistence(model: model, store: store)
            try await removal(model: model, store: store)
            try await staleEdits(
                model: model, store: store, fixture: fixture, firstID: document.id,
                circleID: circleID)
            try require(try digest(fixture) == originalHash, "Input RAW was modified.")
            let copied = try CatalogRepository(rootURL: catalogURL).sourceURL(for: document)
            try require(try digest(copied) == originalHash, "Copied catalog original was modified.")
            model.cancel()
            evidence("MASK INSPECTOR INTEGRATION PASS \(root.path)")
        }

        @MainActor
        private static func shapes(model: MaskInspectorModel, store: EditorStore) async throws -> Int32 {
            let initialHistory = store.history.count
            model.add(.circle)
            await model.waitForApply()
            guard let circle = model.selectedForm, case .circle = circle.geometry else {
                throw MaskWorkflowFailure(
                    message: "Circle creation failed: \(model.errorMessage ?? "unknown")")
            }
            try require(
                store.history.count == initialHistory + 1, "Add circle was not one accepted history entry.")
            model.draftName = "Numeric circle"
            model.setGeometry(
                .circle(
                    CircleMask(
                        center: MaskPoint(horizontal: 0.35, vertical: 0.55),
                        radius: 0.18, feather: 0.03)))
            model.setValidity("radius", valid: false)
            try require(!model.canApply, "Invalid numeric input enabled Apply.")
            model.setValidity("radius", valid: true)
            try require(model.canApply, "Valid numeric geometry did not enable Apply.")
            let editCount = store.history.count
            model.apply()
            await model.waitForApply()
            guard case .circle(let updated) = model.selectedForm?.geometry else {
                throw MaskWorkflowFailure(message: "Circle numeric edit did not decode.")
            }
            try require(
                abs(updated.center.horizontal - 0.35) < 0.000_001
                    && abs(updated.radius - 0.18) < 0.000_001,
                "Circle values did not roundtrip to the engine.")
            try require(store.history.count == editCount + 1, "Numeric draft created extra history entries.")
            try require(!model.hasChanges, "Decoded Float geometry became a false dirty draft.")
            evidence("PASS real circle add/edit, numeric validation and accepted history")
            return circle.id
        }

        @MainActor
        private static func ellipse(model: MaskInspectorModel) async throws {
            model.add(.ellipse)
            await model.waitForApply()
            guard case .ellipse(var ellipse) = model.draftGeometry else {
                throw MaskWorkflowFailure(message: "Ellipse creation failed.")
            }
            ellipse.radius = MaskPoint(horizontal: 0.25, vertical: 0.12)
            ellipse.rotation = 30
            ellipse.featherMode = .proportional
            ellipse.feather = 1.5
            model.setGeometry(.ellipse(ellipse))
            model.apply()
            await model.waitForApply()
            guard case .ellipse(let acceptedEllipse) = model.selectedForm?.geometry else {
                throw MaskWorkflowFailure(message: "Ellipse edit did not decode.")
            }
            try require(
                acceptedEllipse.featherMode == .proportional
                    && abs(acceptedEllipse.feather - 1.5) < 0.000_001, "Ellipse options did not roundtrip.")
            evidence("PASS real ellipse add/edit, radius, rotation and feather mode")
        }

        @MainActor
        private static func gradient(model: MaskInspectorModel) async throws {
            model.add(.gradient)
            await model.waitForApply()
            guard case .gradient(var gradient) = model.draftGeometry else {
                throw MaskWorkflowFailure(message: "Gradient creation failed.")
            }
            gradient.rotation = -25
            gradient.curvature = 0.4
            gradient.transition = .sigmoidal
            model.setGeometry(.gradient(gradient))
            model.apply()
            await model.waitForApply()
            guard case .gradient(let acceptedGradient) = model.selectedForm?.geometry else {
                throw MaskWorkflowFailure(message: "Gradient edit did not decode.")
            }
            try require(
                acceptedGradient.transition == .sigmoidal
                    && abs(acceptedGradient.curvature - 0.4) < 0.000_001,
                "Gradient options did not roundtrip.")
            evidence("PASS real gradient add/edit, curvature, rotation and transition")
        }
    }

    extension MaskInspectorWorkflow {

        @MainActor
        private static func grouping(
            model: MaskInspectorModel, store: EditorStore,
            circleID: Int32
        ) async throws -> Int32 {
            model.chooseForm(circleID)
            model.add(.group)
            await model.waitForApply()
            guard let group = model.selectedForm, case .group(let members) = group.geometry else {
                throw MaskWorkflowFailure(message: "Group creation failed.")
            }
            try require(
                members.count == 1 && members.first?.maskID == circleID,
                "New group did not retain its selected member.")
            guard
                let ellipse = model.state?.forms.first(where: {
                    if case .ellipse = $0.geometry { return true }
                    return false
                })
            else { throw MaskWorkflowFailure(message: "Missing ellipse member.") }
            model.addMember(ellipse.id)
            model.updateMember(1) {
                $0.opacity = 0.7
                $0.operation = .difference
                $0.inverted = true
            }
            model.moveMember(1, by: -1)
            model.apply()
            await model.waitForApply()
            guard case .group(let reordered) = model.selectedForm?.geometry else {
                throw MaskWorkflowFailure(message: "Ordered group edit did not decode.")
            }
            try require(
                reordered.first?.maskID == ellipse.id && reordered.first?.operation == .difference
                    && reordered.first?.inverted == true
                    && abs((reordered.first?.opacity ?? 0) - 0.7) < 0.000_001,
                "Member order/opacity/operation/inversion did not roundtrip.")
            try require(!model.canAddMember(group.id), "Group offered a self-cycle.")
            model.removeMember(0)
            model.apply()
            await model.waitForApply()
            evidence("PASS ordered group members, opacity, combine/invert and member removal")
            return group.id
        }

        @MainActor
        private static func blending(
            model: MaskInspectorModel, store: EditorStore,
            groupID: Int32
        ) async throws {
            guard let exposure = store.currentEdits.modules.first(where: { $0.operation == "exposure" }),
                let assetID = store.selectedAssetID
            else {
                throw MaskWorkflowFailure(message: "Real exposure module unavailable.")
            }
            let edits = store.currentEdits
            let applied = try await store.commitCurrentModule(
                assetID: assetID, catalogID: store.catalogID,
                expectedEdits: edits, module: exposure, values: ["exposure": .number(1.5)],
                label: "Test exposure")
            try require(applied, "Real exposure setup was rejected.")
            await store.waitForRender()
            guard let uniform = store.preview else {
                throw MaskWorkflowFailure(message: "Uniform exposure render failed.")
            }
            let uniformPixels = try pixels(uniform.imageURL)
            model.activate()
            await model.waitForLoad()
            model.chooseModule(exposure.id)
            guard let original = model.selectedBlend else {
                throw MaskWorkflowFailure(message: "Missing seeded blend.")
            }
            try require(
                model.canEditBlend && original.supportsDrawnMasks,
                "Exposure seed did not support drawn masks.")
            let assigned = try await assignGroup(
                model: model, store: store, groupID: groupID,
                exposureID: exposure.id, uniformPixels: uniformPixels)
            try await blendScalars(model: model, assigned: assigned)
            model.chooseForm(groupID)
            try require(!model.selectedReferences.isEmpty, "Assigned group deletion was not guarded.")
            evidence("PASS RAW mask pixel effect, seeded opacity/mode/reverse and module assignment")
        }

        @MainActor
        private static func assignGroup(
            model: MaskInspectorModel, store: EditorStore, groupID: Int32,
            exposureID: UUID, uniformPixels: String
        ) async throws -> BlendState {
            let unrelated = store.currentEdits.modules.filter { $0.id != exposureID }
            let beforeHistory = store.history.count
            model.draftGroupID = groupID
            model.apply()
            await model.waitForApply()
            await store.waitForRender()
            guard let assigned = model.selectedBlend, let masked = store.preview else {
                throw MaskWorkflowFailure(
                    message: "Group assignment/render failed: \(model.errorMessage ?? "unknown")")
            }
            try require(
                assigned.maskID == groupID && assigned.maskMode.contains(.drawn),
                "Drawn group assignment did not reach real engine state.")
            try require(
                try pixels(masked.imageURL) != uniformPixels,
                "Real drawn mask left developed RAW pixels unchanged.")
            try require(store.history.count == beforeHistory + 1, "Assignment was not one history entry.")
            try require(
                store.currentEdits.modules.filter { $0.id != exposureID } == unrelated,
                "Assignment changed unrelated module state.")
            return assigned
        }

        @MainActor
        private static func blendScalars(model: MaskInspectorModel, assigned: BlendState) async throws {
            model.draftOpacity = 62.5
            model.draftMode = BlendMode.multiply.rawValue
            model.draftReversed = true
            model.apply()
            await model.waitForApply()
            guard let changed = model.selectedBlend else {
                throw MaskWorkflowFailure(message: "Blend edit failed.")
            }
            try require(
                abs(changed.opacity - 62.5) < 0.000_001 && changed.mode & 0xFF == BlendMode.multiply.rawValue
                    && changed.mode & 0x8000_0000 != 0, "Seeded opacity/mode/reverse did not roundtrip.")
            try require(
                changed.maskID == assigned.maskID && changed.maskCombine == assigned.maskCombine,
                "Blend scalar edit dropped mask fields.")
        }
    }

    extension MaskInspectorWorkflow {

        @MainActor
        private static func persistence(model: MaskInspectorModel, store: EditorStore) async throws {
            await store.waitForRender()
            guard let before = store.preview else {
                throw MaskWorkflowFailure(message: "Blend render failed.")
            }
            let acceptedPixels = try pixels(before.imageURL)
            let accepted = store.currentEdits
            store.undo()
            await store.waitForRender()
            store.redo()
            await store.waitForRender()
            try require(store.currentEdits == accepted, "Undo/redo changed accepted mask state.")
            guard let restored = store.preview else {
                throw MaskWorkflowFailure(message: "Redo render failed.")
            }
            try require(
                try pixels(restored.imageURL) == acceptedPixels,
                "Redo did not restore exact developed pixels.")
            try store.saveCatalog()
            let reopened = try EditorStore(engine: store.engine, catalogURL: store.catalogURL)
            try require(
                reopened.currentEdits == accepted && reopened.history == store.history,
                "Save/reopen lost masks/blends/history.")
            model.synchronize()
            await model.waitForLoad()
            try require(!model.hasChanges, "History navigation retained a stale mask draft.")
            evidence("PASS undo/redo developed pixels and full-state catalog save/reopen")
        }

        @MainActor
        private static func removal(model: MaskInspectorModel, store: EditorStore) async throws {
            guard
                let gradient = model.state?.forms.first(where: {
                    if case .gradient = $0.geometry { return true }
                    return false
                })
            else { throw MaskWorkflowFailure(message: "Missing removable gradient.") }
            model.chooseForm(gradient.id)
            try require(model.selectedReferences.isEmpty, "Unused gradient has unexpected references.")
            model.removeSelected()
            await model.waitForApply()
            try require(
                model.state?.forms.contains(where: { $0.id == gradient.id }) == false,
                "Remove did not reach real engine masks.")
            store.undo()
            model.synchronize()
            await model.waitForLoad()
            try require(
                model.state?.forms.contains(where: { $0.id == gradient.id }) == true,
                "Undo did not restore removed geometry.")
            evidence("PASS mask deletion, dangling-reference guard and undo restoration")
        }

        @MainActor
        private static func staleEdits(
            model: MaskInspectorModel, store: EditorStore,
            fixture: URL, firstID: UUID, circleID: Int32
        ) async throws {
            await store.importURLs([fixture])
            guard let secondID = store.selectedAssetID, secondID != firstID else {
                throw MaskWorkflowFailure(message: "Second RAW import failed.")
            }
            store.selectAsset(firstID)
            model.activate()
            await model.waitForLoad()
            model.chooseForm(circleID)
            let accepted = store.currentEdits
            let acceptedHistory = store.history
            try await staleDraft(model: model, store: store, firstID: firstID, secondID: secondID)
            model.draftName = "Cancelled draft"
            model.apply()
            model.cancelApply()
            await model.waitForApply()
            try require(store.currentEdits == accepted, "Cancelled mask edit committed history.")
            model.draftName = "Stale A/B/A"
            model.apply()
            await Task.yield()
            store.selectAsset(secondID)
            store.selectAsset(firstID)
            await model.waitForApply()
            try require(store.currentEdits == accepted, "A/B/A selection accepted a stale mask edit.")
            model.activate()
            await model.waitForLoad()
            model.draftName = "Stale catalog"
            model.apply()
            await Task.yield()
            let originalCatalog = store.catalogURL
            try store.openCatalog(
                at: originalCatalog.deletingLastPathComponent().appendingPathComponent("OtherCatalog"))
            model.synchronize()
            await model.waitForApply()
            try require(store.documents.isEmpty, "Stale edit affected another catalog.")
            try store.openCatalog(at: originalCatalog)
            try require(
                store.documents.first(where: { $0.id == firstID })?.edits == accepted
                    && store.documents.first(where: { $0.id == firstID })?.history == acceptedHistory,
                "Catalog switch accepted the stale edit into original history.")
            evidence("PASS real-helper cancel and stale asset A/B/A/catalog suppression")
        }

        @MainActor
        private static func staleDraft(
            model: MaskInspectorModel, store: EditorStore,
            firstID: UUID, secondID: UUID
        ) async throws {
            model.draftName = "Draft before selection round trip"
            let edits = store.currentEdits
            let history = store.history
            store.selectAsset(secondID)
            store.selectAsset(firstID)
            try require(
                store.currentEdits == edits && !model.canApply,
                "Identical edit bytes allowed a draft from an old selection revision.")
            model.apply()
            try require(
                store.history == history, "Stale draft added accepted history before the engine call.")
            model.synchronize()
            await model.waitForLoad()
            model.draftName = "Draft before history round trip"
            store.undo()
            store.redo()
            try require(
                store.currentEdits == edits && !model.canApply,
                "Undo/redo to identical edits allowed an old mask draft.")
            model.synchronize()
            await model.waitForLoad()
            try require(!model.hasChanges, "Revision refresh retained an old numeric draft.")
            evidence("PASS stale drafts rejected before Apply after asset/history revision round trips")
        }

        private static func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw MaskWorkflowFailure(message: message) }
        }
        private static func evidence(_ message: String) {
            FileHandle.standardOutput.write(Data("\(message)\n".utf8))
        }
        private static func digest(_ url: URL) throws -> String {
            SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        private static func pixels(_ url: URL) throws -> String {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                let data = image.dataProvider?.data
            else { throw MaskWorkflowFailure(message: "Cannot decode developed pixels.") }
            return SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined()
        }
    }
#endif
