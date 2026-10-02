import CryptoKit
import Foundation
import ImageIO

@main
struct EngineSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw PhotoEngineError.processing("fixture and output required") }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let originalHash = try SHA256.hash(data: Data(contentsOf: fixture)).description
        let engine = NativePhotoEngineFactory.make(cacheDirectory: root)
        let prepared = try await engine.prepare(sourceURL: fixture, edits: .original)
        guard prepared.edits.modules.count >= 90, prepared.edits.darktableXMP != nil else {
            throw PhotoEngineError.processing("missing actual module/XMP state")
        }
        let identifier = UUID()
        let baseline = try await engine.render(RenderRequest(
            assetID: identifier, generation: 1, sourceURL: fixture, edits: prepared.edits, maximumDimension: 1024
        ))
        var exposureEdits = prepared.edits
        exposureEdits.exposureEV = 1
        let exposure = try await engine.render(RenderRequest(
            assetID: identifier, generation: 2, sourceURL: fixture, edits: exposureEdits, maximumDimension: 1024
        ))
        var whiteBalanceEdits = prepared.edits
        whiteBalanceEdits.temperature = 4000
        let whiteBalance = try await engine.render(RenderRequest(
            assetID: identifier, generation: 3, sourceURL: fixture, edits: whiteBalanceEdits, maximumDimension: 1024
        ))
        guard try pixels(baseline.imageURL) != pixels(exposure.imageURL),
              try pixels(baseline.imageURL) != pixels(whiteBalance.imageURL) else {
            throw PhotoEngineError.processing("adjustments did not change decoded pixels")
        }
        let exports = try await exportProfiles(engine: engine, fixture: fixture, root: root, edits: prepared.edits)
        try await checkCancellation(engine: engine, fixture: fixture, edits: prepared.edits)
        guard try SHA256.hash(data: Data(contentsOf: fixture)).description == originalHash,
              !FileManager.default.fileExists(atPath: fixture.path + ".xmp") else {
            throw PhotoEngineError.processing("fixture changed")
        }
        let evidence: [String: Any] = [
            "engine": engine.capabilities.revision, "moduleStates": prepared.edits.modules.count,
            "dimensions": [baseline.pixelWidth, baseline.pixelHeight],
            "baseline": baseline.imageURL.path, "exposure": exposure.imageURL.path,
            "whiteBalance": whiteBalance.imageURL.path, "exports": exports,
            "cancellation": "passed", "sourcePreserved": true
        ]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("smoke.json"), options: .atomic)
        print("Engine integration passed: RAW prepare, XMP/modules, decoded exposure/WB, ICC exports, cancellation.")
    }

    private static func exportProfiles(
        engine: any PhotoEngine, fixture: URL, root: URL, edits: EditState
    ) async throws -> [[String: String]] {
        var exports: [[String: String]] = []
        for profile in ExportColorSpace.allCases {
            let destination = root.appendingPathComponent("\(profile.rawValue).tiff")
            let result = try await engine.export(ExportRequest(
                assetID: UUID(), sourceURL: fixture, edits: edits, destinationURL: destination,
                format: .tiff, colorSpace: profile, quality: 0.95, maximumDimension: 1024
            ))
            guard FileManager.default.fileExists(atPath: result.destinationURL.path) else {
                throw PhotoEngineError.processing("requested export path missing")
            }
            exports.append(["profile": result.colorSpaceName, "path": result.destinationURL.path])
        }
        return exports
    }

    private static func checkCancellation(engine: any PhotoEngine, fixture: URL, edits: EditState) async throws {
        let cancellation = Task {
            try await engine.render(RenderRequest(
                assetID: UUID(), generation: 4, sourceURL: fixture,
                edits: edits, maximumDimension: 0
            ))
        }
        try await Task.sleep(for: .milliseconds(100))
        cancellation.cancel()
        do {
            _ = try await cancellation.value
            throw PhotoEngineError.processing("cancelled work returned an image")
        } catch is CancellationError {}
    }

    private static func pixels(_ url: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let data = image.dataProvider?.data else {
            throw PhotoEngineError.invalidOutput("undecodable image")
        }
        return SHA256.hash(data: data as Data).description
    }
}
