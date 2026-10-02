import Foundation

enum CameraWhiteBalance {
    static func prepare(engine: any PhotoEngine, sourceURL: URL, cacheURL: URL) async throws -> EditState {
        let directory = cacheURL.appendingPathComponent("CameraWhiteBalance/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cameraSource = directory.appendingPathComponent(sourceURL.lastPathComponent)
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: sourceURL.resolvingSymlinksInPath(), to: cameraSource)
        }.value
        try Task.checkCancellation()
        return try await engine.prepare(sourceURL: cameraSource, edits: .original).edits
    }
}
