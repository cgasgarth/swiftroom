import CryptoKit
import Foundation
import ImageIO

@main
struct ModuleSmoke {
    static func main() async throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let engine = NativePhotoEngineFactory.make(cacheDirectory: root)
        let descriptors = try await engine.modules()
        let schema = try await engine.schema(for: "exposure")
        let prepared = try await engine.prepare(sourceURL: fixture, edits: .original)
        guard descriptors.count == 93, descriptors.filter(\.hasIntrospection).count == 90,
              schema.parametersVersion == 7, schema.parametersSize == 28,
              let module = prepared.edits.modules.first(where: { $0.operation == "exposure" }) else {
            throw PhotoEngineError.processing("module identity/schema integration failed")
        }
        let original = try await engine.parameters(for: module)
        let updated = try await engine.updating(module: module, values: [
            "exposure": .number(1.25), "mode": .text("EXPOSURE_MODE_MANUAL"),
            "compensate_exposure_bias": .boolean(false)
        ])
        let values = try await engine.parameters(for: updated)
        guard values["exposure"]?.doubleValue == 1.25, values["compensate_exposure_bias"] == .boolean(false),
              values["black"] == original["black"], updated.blendParameters == module.blendParameters,
              updated.id == module.id, updated.order == module.order, updated.instance == module.instance else {
            throw PhotoEngineError.processing("module parameter roundtrip altered unrelated state")
        }
        do {
            _ = try await engine.updating(module: module, values: ["exposure": .number(1000)])
            throw PhotoEngineError.invalidOutput("out-of-range field accepted")
        } catch PhotoEngineError.processing {}
        let baseline = try await engine.render(RenderRequest(
            assetID: UUID(), generation: 1, sourceURL: fixture, edits: prepared.edits, maximumDimension: 512
        ))
        var edits = prepared.edits
        guard let index = edits.modules.firstIndex(where: { $0.id == module.id }) else {
            throw PhotoEngineError.processing("module missing")
        }
        edits.modules[index] = updated
        let changed = try await engine.render(RenderRequest(
            assetID: UUID(), generation: 2, sourceURL: fixture, edits: edits, maximumDimension: 512
        ))
        guard try pixels(baseline.imageURL) != pixels(changed.imageURL) else {
            throw PhotoEngineError.processing("native module update did not affect decoded pixels")
        }
        let evidence: [String: Any] = [
            "modules": descriptors.count, "introspected": descriptors.filter(\.hasIntrospection).count,
            "exposureVersion": schema.parametersVersion, "parameterBytes": schema.parametersSize,
            "booleanRoundtrip": true, "unrelatedStatePreserved": true, "boundsRejected": true,
            "actualPixelsChanged": true, "baseline": baseline.imageURL.path, "changed": changed.imageURL.path
        ]
        try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appendingPathComponent("module-smoke.json"), options: .atomic)
        print("Module integration passed: live schema, seeded scalar/enum/bool updates, bounds, rendered pixels.")
    }

    private static func pixels(_ url: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let data = image.dataProvider?.data else {
            throw PhotoEngineError.invalidOutput("undecodable image")
        }
        return SHA256.hash(data: data as Data).description
    }
}
