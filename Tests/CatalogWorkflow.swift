import Foundation

@main
enum CatalogWorkflow {
    @MainActor
    static func main() async {
        do {
            let environment = ProcessInfo.processInfo.environment
            let argument = ProcessInfo.processInfo.arguments.dropFirst().first
            guard let fixturePath = environment["NATIVE_PHOTO_FIXTURE"] ?? argument else {
                throw WorkflowFailure("Provide a copied RAW fixture path.")
            }
            let fixture = URL(fileURLWithPath: fixturePath)
            let outputPath = environment["NATIVE_PHOTO_TEST_OUTPUT"] ?? "/tmp/swiftroom-integration"
            let output = URL(fileURLWithPath: outputPath).appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let catalogURL = output.appendingPathComponent("Catalog")
            let engine = NativePhotoEngineFactory.make(cacheDirectory: catalogURL.appendingPathComponent("Cache"))
            let store = try EditorStore(engine: engine, catalogURL: catalogURL)
            let baseline = try await WorkflowSteps.importRaw(store: store, fixture: fixture)
            let exposure = try await WorkflowSteps.adjustExposure(store: store, baseline: baseline)
            let reopened = try await WorkflowSteps.reopen(
                store: store, engine: engine, catalogURL: catalogURL, exposure: exposure)
            try await WorkflowSteps.switchPhotos(store: reopened, baseline: baseline, fixture: fixture)
            try await WorkflowSteps.export(store: reopened, baseline: baseline, fixture: fixture, output: output)
            try await PreviewWorkflow.verify(store: reopened, output: output)
            print("INTEGRATION PASS \(output.path)")
        } catch {
            FileHandle.standardError.write(Data("INTEGRATION FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
}
