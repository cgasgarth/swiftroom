import CryptoKit
import Foundation
import ImageIO

@main
struct MaskIntegration {
    static func main() async throws {
        let started = Date()
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixture = URL(fileURLWithPath: CommandLine.arguments[2])
        let root = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        let originalHash = try hash(source)
        let engine = NativePhotoEngineFactory.make(cacheDirectory: root)
        guard let editor = engine as? any MaskEditingEngine else {
            throw PhotoEngineError.unavailable("mask engine unavailable")
        }
        var input = EditState.original
        input.darktableXMP = try Data(contentsOf: fixture)
        let prepared = try await engine.prepare(sourceURL: source, edits: input)
        let initial = try await editor.maskState(sourceURL: source, edits: prepared.edits)
        guard initial.forms.count == 3,
              let opaque = initial.forms.first(where: { $0.id == 81999 }), opaque.geometry == nil,
              !opaque.pointData.isEmpty,
              let module = prepared.edits.modules.first(where: { $0.operation == "exposure" && $0.instance == 1 })
        else { throw PhotoEngineError.invalidOutput("fixture masks/blend unavailable") }
        let baselinePixels = try await pixels(engine, source: source, edits: prepared.edits)
        let created = try await editor.applyingMasks(
            sourceURL: source, edits: prepared.edits,
            edit: MaskEdit(mutations: definitions.map(MaskMutation.create), blends: [ModuleBlendMutation(
                moduleID: module.id, patch: BlendPatch(
                    mode: .normal, opacity: 90, maskMode: [.enabled, .drawn], maskID: 82004
                )
            )])
        )
        let createdState = try await editor.maskState(sourceURL: source, edits: created.edits)
        try assert(createdState.forms.count == 7, "all native shapes were not created")
        try preserved(original: prepared.edits, updated: created.edits, blendModule: module.id)
        try assert(createdState.forms.first(where: { $0.id == opaque.id }) == opaque, "opaque mask changed")
        let createdPixels = try await pixels(engine, source: source, edits: created.edits)
        try assert(createdPixels != baselinePixels,
                   "mask assignment did not change decoded pixels")
        let geometryChanged = try await editShapes(editor, source: source, edits: created.edits)
        try assert(try await pixels(engine, source: source, edits: geometryChanged.edits) != createdPixels,
                   "edited geometry did not change decoded pixels")
        let changed = try await patchBlend(editor, source: source, edits: geometryChanged.edits, moduleID: module.id)
        let changedPixels = try await pixels(engine, source: source, edits: changed.edits)
        try assert(changedPixels != baselinePixels, "mask geometry did not affect decoded pixels")
        let reopened = try await reopen(engine, source: source, root: root, edits: changed.edits)
        let reopenedState = try await editor.maskState(sourceURL: source, edits: reopened.edits)
        let changedState = try await editor.maskState(sourceURL: source, edits: changed.edits)
        try assert(reopenedState.forms == changedState.forms, "saved XMP lost native geometry")
        try assert(try await pixels(engine, source: source, edits: reopened.edits) == changedPixels,
                   "saved XMP reopened with different decoded pixels")
        try await finish(editor, source: source, root: root, original: prepared,
                         changed: changed, originalHash: originalHash)
        print("Elapsed \(Date().timeIntervalSince(started)) seconds.")
        print("Masks integration passed: numeric shapes, groups, seeded blend, opaque preservation and XMP reopen.")
    }

    static func patchBlend(
        _ editor: any MaskEditingEngine, source: URL, edits: EditState, moduleID: UUID
    ) async throws -> PreparedPhoto {
        let before = try await pixels(editor, source: source, edits: edits)
        let changed = try await editor.applyingMasks(sourceURL: source, edits: edits, edit: MaskEdit(blends: [
            ModuleBlendMutation(moduleID: moduleID,
                                patch: BlendPatch(mode: .multiply, reversed: true, opacity: 35, maskCombine: 2))
        ]))
        let state = try await editor.maskState(sourceURL: source, edits: changed.edits)
        guard let blend = state.blends.first(where: { $0.moduleID == moduleID }) else {
            throw PhotoEngineError.invalidOutput("missing patched blend")
        }
        try assert(blend.mode == BlendMode.multiply.rawValue | 0x80000000 && blend.opacity == 35,
                   "blend fields were not patched")
        try assert(try await pixels(editor, source: source, edits: changed.edits) != before,
                   "blend fields did not change decoded pixels")
        return changed
    }

    static func finish(
        _ editor: any MaskEditingEngine, source: URL, root: URL,
        original: PreparedPhoto, changed: PreparedPhoto, originalHash: String
    ) async throws {
        guard let module = original.edits.modules.first(where: { $0.operation == "exposure" && $0.instance == 1 }),
              let opaque = try await editor.maskState(sourceURL: source, edits: original.edits)
                .forms.first(where: { $0.id == 81999 }) else {
            throw PhotoEngineError.invalidOutput("missing accepted mask state")
        }
        let failures = try await MaskFailures.check(editor, source: source, edits: changed.edits, moduleID: module.id)
        let deleted = try await editor.applyingMasks(
            sourceURL: source, edits: changed.edits, edit: MaskEdit(
                mutations: [82004, 82001, 82002, 82003].map { .delete(id: $0) },
                blends: [ModuleBlendMutation(moduleID: module.id, patch: BlendPatch(maskMode: .enabled, maskID: 0))]
            )
        )
        let deletedState = try await editor.maskState(sourceURL: source, edits: deleted.edits)
        try assert(deletedState.forms.count == 3, "native mask deletion did not persist")
        try assert(deletedState.forms.first(where: { $0.id == opaque.id }) == opaque, "delete lost unsupported mask")
        try preserved(original: original.edits, updated: deleted.edits, blendModule: module.id)
        try assert(try hash(source) == originalHash, "copied RAW was modified")
        let requests = root.appendingPathComponent("Requests")
        try assert(try FileManager.default.contentsOfDirectory(atPath: requests.path).isEmpty, "request leak")
        let evidence: [String: Any] = [
            "shapes": ["circle", "ellipse", "gradient", "ordered group"], "createUpdateDelete": true,
            "blendAssignment": true, "blendOpaqueBytesPreserved": true, "unsupportedClonePathPreserved": true,
            "savedXMPReopenPixelExact": true, "invalidEditsRejected": failures, "rawSHA256": originalHash,
            "unrelatedModulesAndOrderPreserved": true, "requestCleanup": true,
            "coordinateSpace": "normalized input; canvas mapping unavailable"
        ]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("mask-evidence.json"))
    }

    static var definitions: [MaskDefinition] {
        [
            MaskDefinition(id: 82001, name: "Native circle", geometry: .circle(CircleMask(
                center: MaskPoint(horizontal: 0.35, vertical: 0.5), radius: 0.14, feather: 0.05
            ))),
            MaskDefinition(id: 82002, name: "Native ellipse", geometry: .ellipse(EllipseMask(
                center: MaskPoint(horizontal: 0.6, vertical: 0.4), radius: MaskPoint(horizontal: 0.2, vertical: 0.1),
                rotation: 30, feather: 0.06, featherMode: .equidistant
            ))),
            MaskDefinition(id: 82003, name: "Native gradient", geometry: .gradient(GradientMask(
                anchor: MaskPoint(horizontal: 0.4, vertical: 0.6), rotation: 10, compression: 0.3,
                steepness: 0, curvature: 0.2, transition: .linear
            ))),
            MaskDefinition(id: 82004, name: "Native group", geometry: .group([
                MaskGroupMember(maskID: 82001, opacity: 1, operation: .union),
                MaskGroupMember(maskID: 82002, opacity: 0.7, operation: .union),
                MaskGroupMember(maskID: 82003, opacity: 0.8, operation: .intersection)
            ]))
        ]
    }

    static func editShapes(
        _ engine: any MaskEditingEngine, source: URL, edits: EditState
    ) async throws -> PreparedPhoto {
        var changed = definitions
        changed[0].geometry = .circle(CircleMask(center: MaskPoint(horizontal: 0.7, vertical: 0.6),
                                                radius: 0.23, feather: 0.08))
        changed[1].geometry = .ellipse(EllipseMask(center: MaskPoint(horizontal: 0.4, vertical: 0.3),
            radius: MaskPoint(horizontal: 0.1, vertical: 0.25),
            rotation: -45, feather: 0.3, featherMode: .proportional))
        changed[2].geometry = .gradient(GradientMask(anchor: MaskPoint(horizontal: 0.5, vertical: 0.5),
            rotation: 70, compression: 0.2, steepness: 0.1, curvature: -0.4, transition: .sigmoidal))
        changed[3].geometry = .group([
            MaskGroupMember(maskID: 82003, opacity: 0.8, operation: .union),
            MaskGroupMember(maskID: 82002, opacity: 0.9, operation: .difference, inverted: true),
            MaskGroupMember(maskID: 82001, opacity: 0.6, operation: .union)
        ])
        return try await engine.applyingMasks(sourceURL: source, edits: edits, edit: MaskEdit(mutations:
            changed.map { .update(id: $0.id, name: "Edited \($0.name)", geometry: $0.geometry) }
        ))
    }

    static func preserved(original: EditState, updated: EditState, blendModule: UUID) throws {
        for module in original.modules {
            guard let changed = updated.modules.first(where: { $0.id == module.id }) else {
                throw PhotoEngineError.invalidOutput("unrelated module identity lost")
            }
            if module.id != blendModule {
                try assert(changed == module,
                           "unrelated \(module.operation)/\(module.instance) changed: " +
                           "enabled \(module.enabled)->\(changed.enabled), order \(module.order)->\(changed.order), " +
                           "params \(module.parameters == changed.parameters), " +
                           "blend \(module.blendParameters == changed.blendParameters), " +
                           "name \(module.name == changed.name)")
            } else {
                try assert(changed.parameters == module.parameters && changed.order == module.order,
                           "blend edit changed module parameters/order")
                guard let before = module.blendParameters, let after = changed.blendParameters else {
                    throw PhotoEngineError.invalidOutput("missing blend seed")
                }
                let allowed = Set(Array(0..<4) + Array(8..<12) + Array(16..<28))
                try assert(before.count == after.count && before.indices.allSatisfy {
                    allowed.contains($0) || before[$0] == after[$0]
                }, "blend patch changed unrelated parameter bytes")
            }
        }
    }

    static func reopen(
        _ engine: any PhotoEngine, source: URL, root: URL, edits: EditState
    ) async throws -> PreparedPhoto {
        guard let xmp = edits.darktableXMP else { throw PhotoEngineError.invalidOutput("missing complete XMP") }
        let file = root.appendingPathComponent("saved.xmp")
        try xmp.write(to: file, options: .atomic)
        var reopened = EditState.original
        reopened.darktableXMP = try Data(contentsOf: file)
        return try await engine.prepare(sourceURL: source, edits: reopened)
    }

    static func pixels(_ engine: any PhotoEngine, source: URL, edits: EditState) async throws -> String {
        let photo = try await engine.render(RenderRequest(assetID: UUID(), generation: 1,
            sourceURL: source, edits: edits, maximumDimension: 512))
        guard let imageSource = CGImageSourceCreateWithURL(photo.imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
              let data = image.dataProvider?.data else { throw PhotoEngineError.invalidOutput("missing pixels") }
        let digest = SHA256.hash(data: data as Data).description
        await engine.release(photo)
        return digest
    }

    static func hash(_ file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file)).description
    }

    static func assert(_ condition: Bool, _ message: String) throws {
        if !condition { throw PhotoEngineError.invalidOutput(message) }
    }
}
