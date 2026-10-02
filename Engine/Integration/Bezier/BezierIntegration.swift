import CryptoKit
import Foundation
import ImageIO

@main
struct BezierIntegration {
    static func main() async throws {
        let started = Date()
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        let originalHash = try SHA256.hash(data: Data(contentsOf: source)).description
        let engine = NativePhotoEngineFactory.make(cacheDirectory: root)
        guard let editor = engine as? any MaskEditingEngine else {
            throw PhotoEngineError.unavailable("mask engine")
        }
        var input = EditState.original
        input.darktableXMP = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let prepared = try await engine.prepare(sourceURL: source, edits: input)
        guard let module = prepared.edits.modules.first(where: { $0.operation == "exposure" && $0.instance == 1 })
        else { throw PhotoEngineError.invalidOutput("seeded exposure instance missing") }
        let initial = try await editor.maskState(sourceURL: source, edits: prepared.edits)
        let baselinePixels = try await pixels(engine, source: source, edits: prepared.edits)
        let created = try await editor.applyingMasks(sourceURL: source, edits: prepared.edits, edit: MaskEdit(
            mutations: [
                .create(MaskDefinition(id: 84001, name: "Native path", geometry: .path(path))),
                .create(MaskDefinition(id: 84002, name: "Native brush", geometry: .brush(brush))),
                .create(MaskDefinition(id: 84003, name: "Bezier group", geometry: .group([
                    MaskGroupMember(maskID: 84001, opacity: 1, operation: .union)
                ])))
            ], blends: [ModuleBlendMutation(moduleID: module.id, patch: BlendPatch(opacity: 90, maskID: 84003))]
        ))
        try await preserved(editor, source: source, original: initial, edits: created.edits)
        try BezierPreservation.modules(original: prepared.edits, updated: created.edits, target: module.id)
        let pathPixels = try await pixels(engine, source: source, edits: created.edits)
        try require(pathPixels != baselinePixels, "path assignment did not change decoded pixels")
        let changedPath = try await editPath(editor, source: source, edits: created.edits)
        try require(try await pixels(engine, source: source, edits: changedPath.edits) != pathPixels,
                    "path controls did not change decoded pixels")
        let changedBrush = try await editBrush(editor, source: source, edits: changedPath.edits)
        try BezierPreservation.modules(original: prepared.edits, updated: changedBrush.edits, target: module.id)
        try await reopenAndDelete(editor, source: source, root: root, edits: changedBrush.edits,
                                  initial: initial, moduleID: module.id)
        let rejected = try await failures(editor, source: source, edits: changedBrush.edits)
        try await BezierPreservation.cancel(editor, source: source, root: root, edits: changedBrush.edits)
        try require(try SHA256.hash(data: Data(contentsOf: source)).description == originalHash, "copied RAW changed")
        let evidence: [String: Any] = ["pathBrushLifecycle": true, "decodedPixelsChanged": true,
            "savedXMPPixelExact": true, "unsupportedFormsPreserved": true, "unrelatedModulesPreserved": true,
            "blendOpaqueBytesPreserved": true, "activeCancellation": true, "requestCleanup": true,
            "rejectedTransactions": rejected, "sourceSHA256": originalHash,
            "coordinateSpace": "normalized input; explicit cubic control points",
            "elapsedSeconds": Date().timeIntervalSince(started)]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("bezier-evidence.json"))
        print("Bezier integration passed: real path/brush creation, control edits, grouping, deletion and XMP reopen.")
    }

    static var path: [BezierMaskPoint] {
        [point(0.2, 0.2), point(0.55, 0.2), point(0.55, 0.5), point(0.2, 0.5)]
    }

    static var brush: [BrushMaskPoint] {
        [BrushMaskPoint(curve: point(0.25, 0.65), density: 0.8, hardness: 0.7),
         BrushMaskPoint(curve: point(0.55, 0.6), density: 0.6, hardness: 0.4),
         BrushMaskPoint(curve: point(0.75, 0.75), density: 1, hardness: 0.6)]
    }

    static func point(_ horizontal: Double, _ vertical: Double) -> BezierMaskPoint {
        let corner = MaskPoint(horizontal: horizontal, vertical: vertical)
        return BezierMaskPoint(corner: corner, controlIn: corner, controlOut: corner,
                               feather: MaskPoint(horizontal: 0.035, vertical: 0.035))
    }

    static func editPath(
        _ engine: any MaskEditingEngine, source: URL, edits: EditState
    ) async throws -> PreparedPhoto {
        var points = path
        points[1].corner.horizontal = 0.7
        points[1].controlIn = MaskPoint(horizontal: 0.35, vertical: 0.05)
        points[1].controlOut = MaskPoint(horizontal: 0.85, vertical: 0.4)
        return try await engine.applyingMasks(sourceURL: source, edits: edits, edit: MaskEdit(mutations: [
            .update(id: 84001, name: "Edited cubic path", geometry: .path(points))
        ]))
    }

    static func editBrush(
        _ engine: any MaskEditingEngine, source: URL, edits: EditState
    ) async throws -> PreparedPhoto {
        let assigned = try await engine.applyingMasks(sourceURL: source, edits: edits,
                                                     edit: MaskEdit(mutations: [
            .update(id: 84003, geometry: .group([MaskGroupMember(maskID: 84002, opacity: 1, operation: .union)]))
        ]))
        let before = try await pixels(engine, source: source, edits: assigned.edits)
        var points = brush
        points[1].curve.controlIn = MaskPoint(horizontal: 0.35, vertical: 0.85)
        points[1].curve.controlOut = MaskPoint(horizontal: 0.7, vertical: 0.35)
        points[1].density = 0.2
        points[1].hardness = 0.1
        let changed = try await engine.applyingMasks(sourceURL: source, edits: assigned.edits,
                                                    edit: MaskEdit(mutations: [
            .update(id: 84002, name: "Edited cubic brush", geometry: .brush(points))
        ]))
        try require(try await pixels(engine, source: source, edits: changed.edits) != before,
                    "brush controls/density/hardness did not change decoded pixels")
        return changed
    }

    static func preserved(
        _ engine: any MaskEditingEngine, source: URL, original: MaskState, edits: EditState
    ) async throws {
        let state = try await engine.maskState(sourceURL: source, edits: edits)
        for form in original.forms {
            try require(state.forms.first(where: { $0.id == form.id }) == form, "existing mask payload changed")
        }
        guard case .path(let points) = state.forms.first(where: { $0.id == 84001 })?.geometry,
              case .brush(let stroke) = state.forms.first(where: { $0.id == 84002 })?.geometry,
              points.count == 4, stroke.count == 3 else {
            throw PhotoEngineError.invalidOutput("typed Bezier point listing failed")
        }
    }

    static func reopenAndDelete(
        _ engine: any MaskEditingEngine, source: URL, root: URL, edits: EditState,
        initial: MaskState, moduleID: UUID
    ) async throws {
        guard let xmp = edits.darktableXMP else { throw PhotoEngineError.invalidOutput("missing complete XMP") }
        let file = root.appendingPathComponent("saved.xmp")
        try xmp.write(to: file, options: .atomic)
        var input = EditState.original
        input.darktableXMP = try Data(contentsOf: file)
        let reopened = try await engine.prepare(sourceURL: source, edits: input)
        let state = try await engine.maskState(sourceURL: source, edits: edits)
        let loaded = try await engine.maskState(sourceURL: source, edits: reopened.edits)
        try require(loaded.forms == state.forms, "XMP lost Bezier point bytes")
        let originalPixels = try await pixels(engine, source: source, edits: edits)
        let repeatedPixels = try await pixels(engine, source: source, edits: edits)
        try require(originalPixels == repeatedPixels, "identical brush render changed decoded pixels")
        let reopenedPixels = try await pixels(engine, source: source, edits: reopened.edits)
        try require(reopenedPixels == originalPixels, "XMP reopen changed decoded pixels")
        let deleted = try await engine.applyingMasks(sourceURL: source, edits: edits, edit: MaskEdit(
            mutations: [84003, 84001, 84002].map { .delete(id: $0) },
            blends: [ModuleBlendMutation(moduleID: moduleID, patch: BlendPatch(maskID: 81002))]
        ))
        let deletedState = try await engine.maskState(sourceURL: source, edits: deleted.edits)
        try require(deletedState.forms == initial.forms, "Bezier deletion lost original forms")
    }

    static func failures(_ engine: any MaskEditingEngine, source: URL, edits: EditState) async throws -> Int {
        let accepted = try await engine.maskState(sourceURL: source, edits: edits)
        var invalidCurve = path
        invalidCurve[0].controlOut.horizontal = 4
        var invalidBrush = brush
        invalidBrush[0].hardness = 2
        let mutations: [MaskMutation] = [
            .update(id: 84001, geometry: .path(Array(path.prefix(2)))),
            .update(id: 84002, geometry: .brush(Array(brush.prefix(1)))),
            .update(id: 84001, geometry: .path(invalidCurve)),
            .update(id: 84002, geometry: .brush(invalidBrush)),
            .update(id: 81999, geometry: .path(path))
        ]
        for mutation in mutations {
            do {
                _ = try await engine.applyingMasks(sourceURL: source, edits: edits,
                                                   edit: MaskEdit(mutations: [mutation]))
                throw PhotoEngineError.invalidOutput("invalid Bezier mutation accepted")
            } catch PhotoEngineError.processing { continue }
        }
        let unchanged = try await engine.maskState(sourceURL: source, edits: edits)
        try require(unchanged == accepted, "failed Bezier mutation changed accepted state")
        return mutations.count
    }

    static func pixels(_ engine: any PhotoEngine, source: URL, edits: EditState) async throws -> String {
        let rendered = try await engine.render(RenderRequest(assetID: UUID(), generation: 1,
            sourceURL: source, edits: edits, maximumDimension: 512))
        guard let imageSource = CGImageSourceCreateWithURL(rendered.imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
              let data = image.dataProvider?.data else { throw PhotoEngineError.invalidOutput("missing pixels") }
        let hash = SHA256.hash(data: data as Data).description
        await engine.release(rendered)
        return hash
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw PhotoEngineError.invalidOutput(message) }
    }
}
