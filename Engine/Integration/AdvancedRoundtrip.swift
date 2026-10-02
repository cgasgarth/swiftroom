import CryptoKit
import Foundation
import ImageIO

@main
struct AdvancedRoundtrip {
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else {
            throw PhotoEngineError.processing("RAW, generated XMP and output directory required")
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let xmp = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let root = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        let engine = NativePhotoEngineFactory.make(cacheDirectory: root)
        var input = EditState.original
        input.darktableXMP = xmp
        let prepared = try await engine.prepare(sourceURL: source, edits: input)
        guard let original = prepared.edits.darktableXMP,
              let instance = prepared.edits.modules.first(where: { $0.operation == "exposure" && $0.instance == 1 }),
              instance.name == "Local spotlight", instance.enabled, instance.blendVersion == 14,
              try masks(original) == masks(xmp), try masks(original).count == 2 else {
            throw PhotoEngineError.processing("import lost actual instance, blend or mask geometry")
        }
        let baseline = try await engine.render(RenderRequest(
            assetID: UUID(), generation: 1, sourceURL: source, edits: prepared.edits, maximumDimension: 512
        ))
        var changed = try await engine.updating(module: instance, values: ["exposure": .number(3)])
        changed.name = "Preserved spotlight"
        var edits = prepared.edits
        edits.modules = edits.modules.map { $0.id == instance.id ? changed : $0 }
        let updated = try await engine.prepare(sourceURL: source, edits: edits)
        guard let updatedXMP = updated.edits.darktableXMP,
              let updatedInstance = updated.edits.modules.first(where: {
                  $0.operation == "exposure" && $0.instance == 1
              }), updatedInstance.name == changed.name,
              updatedInstance.blendParameters == instance.blendParameters,
              try masks(updatedXMP) == masks(original), ordered(updated.edits) else {
            throw PhotoEngineError.processing("scalar commit lost label, blend, masks or pipeline order")
        }
        let rendered = try await engine.render(RenderRequest(
            assetID: baseline.assetID, generation: 2, sourceURL: source,
            edits: updated.edits, maximumDimension: 512
        ))
        guard try pixels(baseline.imageURL) != pixels(rendered.imageURL) else {
            throw PhotoEngineError.processing("masked exposure edit did not change actual pixels")
        }
        let reopenedXMP = try await reopen(
            engine, source: source, root: root, original: original, updated: updated.edits
        )
        try await checkInstances(engine, source: source, edits: updated.edits, instance: updatedInstance)
        try await checkLabel(engine, source: source, edits: updated.edits, instance: updatedInstance)
        try FileManager.default.copyItem(at: baseline.imageURL, to: root.appendingPathComponent("baseline.png"))
        try FileManager.default.copyItem(at: rendered.imageURL, to: root.appendingPathComponent("changed.png"))
        await engine.release(baseline)
        await engine.release(rendered)
        try writeEvidence(root: root, xmp: reopenedXMP, instance: updatedInstance)
        print("Advanced integration passed: real masks, blend, instances, order, labels, enabled and XMP reopen.")
    }

    private static func reopen(
        _ engine: any PhotoEngine, source: URL, root: URL, original: Data, updated: EditState
    ) async throws -> Data {
        try original.write(to: root.appendingPathComponent("imported.xmp"))
        let saved = root.appendingPathComponent("saved.xmp")
        guard let xmp = updated.darktableXMP else { throw PhotoEngineError.processing("missing prepared XMP") }
        try xmp.write(to: saved, options: .atomic)
        var edits = EditState.original
        edits.darktableXMP = try Data(contentsOf: saved)
        let prepared = try await engine.prepare(sourceURL: source, edits: edits)
        guard let reopened = prepared.edits.darktableXMP,
              try masks(reopened) == masks(original), ordered(prepared.edits) else {
            throw PhotoEngineError.processing("saved/reopened XMP lost masks or custom order")
        }
        return reopened
    }

    private static func writeEvidence(root: URL, xmp: Data, instance: ModuleState) throws {
        let evidence: [String: Any] = [
            "maskShapes": try masks(xmp), "blendVersion": instance.blendVersion ?? 0,
            "instance": instance.instance, "maskedPixelsChanged": true,
            "customOrderPreserved": true, "newInstanceApplied": true,
            "labelToggleApplied": true, "oversizeLabelRejected": true, "previewRelease": true,
            "baseline": root.appendingPathComponent("baseline.png").path,
            "changed": root.appendingPathComponent("changed.png").path
        ]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("advanced-roundtrip.json"))
    }

    private static func checkInstances(
        _ engine: any PhotoEngine, source: URL, edits: EditState, instance: ModuleState
    ) async throws {
        var duplicate = instance
        duplicate.id = UUID()
        duplicate.instance = 2
        duplicate.name = "Second spotlight"
        duplicate.order += 0.5
        duplicate.enabled = false
        var updated = edits
        updated.modules.append(duplicate)
        let prepared = try await engine.prepare(sourceURL: source, edits: updated)
        guard prepared.edits.modules.contains(where: {
            $0.operation == "exposure" && $0.instance == 2 && $0.name == duplicate.name && !$0.enabled
        }) else { throw PhotoEngineError.processing("instance creation or label/toggle not applied") }
    }

    private static func checkLabel(
        _ engine: any PhotoEngine, source: URL, edits: EditState, instance: ModuleState
    ) async throws {
        var invalid = instance
        invalid.name = String(repeating: "🟠", count: 32)
        var updated = edits
        updated.modules = updated.modules.map { $0.id == instance.id ? invalid : $0 }
        do {
            _ = try await engine.prepare(sourceURL: source, edits: updated)
            throw PhotoEngineError.invalidOutput("oversize label was accepted")
        } catch PhotoEngineError.processing(let message) {
            guard message.contains("127 UTF-8 bytes") else { throw PhotoEngineError.processing(message) }
        }
    }

    private static func masks(_ data: Data) throws -> [String: [String: String]] {
        let document = try XMLDocument(data: data)
        let nodes = try document.nodes(forXPath: "//*[local-name()='masks_history']//*[local-name()='li']")
        var result: [String: [String: String]] = [:]
        for node in nodes {
            guard let element = node as? XMLElement else { continue }
            var attributes: [String: String] = [:]
            for attribute in element.attributes ?? [] where attribute.localName != "mask_num" {
                if let key = attribute.localName, let value = attribute.stringValue { attributes[key] = value }
            }
            if let identifier = attributes["mask_id"] { result[identifier] = attributes }
        }
        return result
    }

    private static func ordered(_ edits: EditState) -> Bool {
        guard let grading = edits.modules.first(where: { $0.operation == "colorbalancergb" }),
              let sigmoid = edits.modules.first(where: { $0.operation == "sigmoid" }) else { return false }
        return grading.order > sigmoid.order
    }

    private static func pixels(_ url: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let data = image.dataProvider?.data else { throw PhotoEngineError.invalidOutput("undecodable image") }
        return SHA256.hash(data: data as Data).description
    }
}
