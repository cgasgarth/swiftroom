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
        try await checkDescriptions(engine)
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
        let retained = try await preserveAndRelease(engine, photos: [baseline, exposure, whiteBalance], root: root)
        try await checkCleanup(engine, root: root)
        guard try SHA256.hash(data: Data(contentsOf: fixture)).description == originalHash,
              !FileManager.default.fileExists(atPath: fixture.path + ".xmp") else {
            throw PhotoEngineError.processing("fixture changed")
        }
        let evidence: [String: Any] = [
            "engine": engine.capabilities.revision, "moduleStates": prepared.edits.modules.count,
            "dimensions": [baseline.pixelWidth, baseline.pixelHeight],
            "baseline": retained[0].path, "exposure": retained[1].path,
            "whiteBalance": retained[2].path, "exports": exports,
            "cancellation": "passed", "sourcePreserved": true, "scratchCleanup": true,
            "previewRelease": true, "wrongICCRejected": true, "incompatibleRuntimeRejected": true
        ]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("smoke.json"), options: .atomic)
        print("Engine integration passed: RAW prepare, XMP/modules, decoded exposure/WB, ICC exports, cancellation.")
    }

    private static func checkDescriptions(_ engine: any PhotoEngine) async throws {
        let schema = try await engine.schema(for: "exposure")
        guard let mode = schema.fields.first(where: { $0.name == "mode" }),
              schema.fields.contains(where: { $0.title == "black level correction" }),
              mode.choices.contains(where: { $0.title == "manual" }) else {
            throw PhotoEngineError.processing("actual introspection descriptions missing")
        }
    }

    private static func exportProfiles(
        engine: any PhotoEngine, fixture: URL, root: URL, edits: EditState
    ) async throws -> [[String: String]] {
        var exports: [[String: String]] = []
        var profiles: [Data] = []
        var destinations: [URL] = []
        for profile in ExportColorSpace.allCases {
            let destination = root.appendingPathComponent("\(profile.rawValue).tiff")
            let result = try await engine.export(ExportRequest(
                assetID: UUID(), sourceURL: fixture, edits: edits, destinationURL: destination,
                format: .tiff, colorSpace: profile, quality: 0.95, maximumDimension: 1024
            ))
            guard FileManager.default.fileExists(atPath: result.destinationURL.path) else {
                throw PhotoEngineError.processing("requested export path missing")
            }
            guard let embedded = try EmbeddedICC.read(result.destinationURL, expectedLength: 2_097_152) else {
                throw PhotoEngineError.invalidOutput("missing actual embedded ICC")
            }
            profiles.append(embedded)
            destinations.append(result.destinationURL)
            exports.append(["profile": result.colorSpaceName, "path": result.destinationURL.path,
                            "iccSHA256": SHA256.hash(data: embedded).description])
        }
        guard Set(profiles).count == 3 else { throw PhotoEngineError.invalidOutput("export profiles are identical") }
        do {
            _ = try ImageValidation.validate(destinations[0], expectedICC: profiles[1])
            throw PhotoEngineError.processing("mismatched embedded ICC accepted")
        } catch PhotoEngineError.invalidOutput {}
        return exports
    }

    private static func preserveAndRelease(
        _ engine: any PhotoEngine, photos: [RenderedPhoto], root: URL
    ) async throws -> [URL] {
        var outputs: [URL] = []
        for (index, photo) in photos.enumerated() {
            let output = root.appendingPathComponent("preview-\(index).png")
            try FileManager.default.copyItem(at: photo.imageURL, to: output)
            await engine.release(photo)
            guard !FileManager.default.fileExists(atPath: photo.imageURL.path) else {
                throw PhotoEngineError.processing("preview release did not remove owned image")
            }
            outputs.append(output)
        }
        return outputs
    }

    private static func checkCleanup(_ engine: any PhotoEngine, root: URL) async throws {
        do {
            _ = try await engine.prepare(sourceURL: root.appendingPathComponent("missing.ARW"), edits: .original)
            throw PhotoEngineError.invalidOutput("missing source accepted")
        } catch PhotoEngineError.processing {}
        let modules = root.appendingPathComponent("WrongRuntime")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data("incompatible-runtime".utf8).write(to: modules.appendingPathComponent("libdarktable.dylib"))
        let verified = try EngineRuntime.locate()
        let runtime = EngineRuntime(
            executable: verified.executable, dataDirectory: verified.dataDirectory, moduleDirectory: modules
        )
        do {
            try runtime.validate()
            throw PhotoEngineError.processing("incompatible runtime accepted")
        } catch PhotoEngineError.unavailable {}
        try FileManager.default.removeItem(at: modules)
        for folder in ["Requests", "Queries", "Previews"] {
            let directory = root.appendingPathComponent(folder)
            let files = FileManager.default.fileExists(atPath: directory.path)
                ? try FileManager.default.contentsOfDirectory(atPath: directory.path) : []
            guard files.isEmpty else {
                throw PhotoEngineError.processing("scratch or preview files leaked")
            }
        }
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
