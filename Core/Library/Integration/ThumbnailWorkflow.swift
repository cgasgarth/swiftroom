#if THUMBNAIL_INTEGRATION
import CryptoKit
import Foundation
import ImageIO

@main
enum ThumbnailWorkflow {
    @MainActor
    static func main() async {
        do {
            guard let path = ProcessInfo.processInfo.environment["NATIVE_PHOTO_FIXTURE"] else {
                throw ThumbnailFailure(message: "Provide a copied RAW via NATIVE_PHOTO_FIXTURE.")
            }
            let fixture = URL(fileURLWithPath: path)
            let originalDigest = try fileDigest(fixture)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("swiftroom-thumbnails-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let inputs = try ["alpha", "bravo", "charlie"].map { name in
                let input = root.appendingPathComponent(name).appendingPathExtension(fixture.pathExtension)
                try FileManager.default.copyItem(at: fixture, to: input)
                return input
            }
            let catalogURL = root.appendingPathComponent("Catalog")
            let engine = NativePhotoEngineFactory.make(cacheDirectory: catalogURL.appendingPathComponent("Cache"))
            let store = try EditorStore(engine: engine, catalogURL: catalogURL)
            await store.importURLs(inputs)
            await store.waitForRender()
            try require(store.documents.count == 3, "Actual RAW import failed: \(store.errorMessage ?? "unknown")")
            guard let canvas = store.preview else { throw ThumbnailFailure(message: "The active canvas has no frame.") }
            let ids = store.documents.map(\.id)
            let service = PhotoThumbnailService(store: store, maximumRetainedFrames: 2)
            let first = Task { await service.request(ids[0]) }
            let second = Task { await service.request(ids[1]) }
            try await waitUntil { service.urls[ids[0]] != nil && service.urls[ids[1]] != nil }
            guard let firstURL = service.urls[ids[0]], let secondURL = service.urls[ids[1]] else {
                throw ThumbnailFailure(message: "Unvisited photos have no real thumbnails.")
            }
            let originalPixels = try verifyImage(secondURL)
            _ = try verifyImage(firstURL)
            try require(store.selectedAssetID == canvas.assetID && store.preview?.imageURL == canvas.imageURL,
                "Thumbnail requests changed the selected canvas.")
            try require(FileManager.default.fileExists(atPath: canvas.imageURL.path),
                "A thumbnail released the canvas.")
            print("PASS real 240px ICC thumbnails for unvisited RAWs without changing selection/canvas")
            let third = try await verifyEviction(store: store, service: service, ids: ids,
                first: first, firstURL: firstURL, secondURL: secondURL)
            let revised = try await verifyRevision(store: store, service: service, id: ids[1],
                third: third, second: second, original: (url: secondURL, pixels: originalPixels))
            try await verifyReset(store: store, service: service, ids: ids, root: root, revised: revised)
            try verifyOriginals(store: store, fixture: fixture, expectedDigest: originalDigest)
            print("PASS source and catalog-original SHA256 unchanged")
            print("THUMBNAIL INTEGRATION PASS \(root.path)")
        } catch {
            FileHandle.standardError.write(Data("THUMBNAIL INTEGRATION FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func verifyEviction(
        store: EditorStore, service: PhotoThumbnailService, ids: [UUID],
        first: Task<Void, Never>, firstURL: URL, secondURL: URL
    ) async throws -> Task<Void, Never> {
        store.selectAsset(ids[2])
        await store.waitForRender()
        guard let canvas = store.preview else { throw ThumbnailFailure(message: "Switching lost the canvas frame.") }
        let third = Task { await service.request(ids[2]) }
        first.cancel()
        await first.value
        try await waitUntil { service.urls[ids[2]] != nil }
        try await waitUntil { !FileManager.default.fileExists(atPath: firstURL.path) }
        try require(service.urls.count <= 2, "The thumbnail cache exceeded its configured bound.")
        try require(FileManager.default.fileExists(atPath: secondURL.path), "The cache evicted a consumed frame.")
        try require(store.preview?.imageURL == canvas.imageURL
            && FileManager.default.fileExists(atPath: canvas.imageURL.path),
            "Cache eviction released the active canvas.")
        print("PASS bounded cache eviction, consumer cancellation and preserved full canvas")
        return third
    }

    @MainActor
    private static func verifyRevision(
        store: EditorStore, service: PhotoThumbnailService, id: UUID,
        third: Task<Void, Never>, second: Task<Void, Never>, original: (url: URL, pixels: String)
    ) async throws -> Task<Void, Never> {
        third.cancel()
        await third.value
        store.selectAsset(id)
        store.setExposure(1)
        await store.waitForRender()
        guard let canvas = store.preview else { throw ThumbnailFailure(message: "Exposure lost the canvas frame.") }
        let revised = Task { await service.request(id) }
        try await waitUntil { service.urls[id] != nil && service.urls[id] != original.url }
        guard let revisedURL = service.urls[id] else { throw ThumbnailFailure(message: "Edited thumbnail is missing.") }
        let revisedPixels = try verifyImage(revisedURL)
        try require(revisedPixels != original.pixels, "The thumbnail ignored the real exposure edit.")
        try require(FileManager.default.fileExists(atPath: original.url.path),
            "A replaced thumbnail was released before its consumer ended.")
        second.cancel()
        await second.value
        try await waitUntil { !FileManager.default.fileExists(atPath: original.url.path) }
        try require(FileManager.default.fileExists(atPath: revisedURL.path), "The cache released the current revision.")
        try require(store.preview?.imageURL == canvas.imageURL
            && FileManager.default.fileExists(atPath: canvas.imageURL.path),
            "Revision cleanup released the full canvas.")
        print("PASS real edited pixels, revision guards and release after the old consumer ends")
        return revised
    }
}

extension ThumbnailWorkflow {
    @MainActor
    private static func verifyOriginals(store: EditorStore, fixture: URL, expectedDigest: String) throws {
        try require(try fileDigest(fixture) == expectedDigest, "The source RAW changed.")
        for document in store.documents {
            let original = try CatalogRepository(rootURL: store.catalogURL).sourceURL(for: document)
            try require(try fileDigest(original) == expectedDigest, "A catalog original changed.")
        }
    }

    @MainActor
    private static func verifyReset(
        store: EditorStore, service: PhotoThumbnailService, ids: [UUID], root: URL,
        revised: Task<Void, Never>
    ) async throws {
        let catalogURL = store.catalogURL
        let retainedURLs = Array(service.urls.values)
        let queued = Task { await service.request(ids[0]) }
        try await waitUntil { service.isRendering }
        let generation = service.generation
        try store.openCatalog(at: root.appendingPathComponent("Alternate"))
        service.reset()
        await queued.value
        await revised.value
        await service.waitUntilIdle()
        try require(service.generation != generation && service.urls.isEmpty,
            "Old-catalog thumbnails published after reset.")
        for url in retainedURLs {
            try await waitUntil { !FileManager.default.fileExists(atPath: url.path) }
        }
        try store.openCatalog(at: catalogURL)
        let reopened = Task { await service.request(ids[1]) }
        try await waitUntil { service.urls[ids[1]] != nil }
        guard let reopenedURL = service.urls[ids[1]] else {
            throw ThumbnailFailure(message: "Reopen has no thumbnail.")
        }
        _ = try verifyImage(reopenedURL)
        reopened.cancel()
        await reopened.value
        service.reset()
        try await waitUntil { !FileManager.default.fileExists(atPath: reopenedURL.path) }
        print("PASS cancellation during real thumbnail work, catalog isolation, reopen and disk cleanup")
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ThumbnailFailure(message: "Timed out waiting for real thumbnail work: 30 seconds.")
    }

    private static func verifyImage(_ url: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let colorSpace = image.colorSpace, let profile = colorSpace.copyICCData(),
              let data = image.dataProvider?.data else { throw ThumbnailFailure(message: "Invalid ICC thumbnail.") }
        try require(image.width > 0 && image.height > 0 && max(image.width, image.height) <= 240,
            "The thumbnail has incorrect pixel dimensions.")
        try require(CFDataGetLength(profile) > 0, "The thumbnail omitted its ICC profile.")
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let profileName = properties?[kCGImagePropertyProfileName] as? String
        try require(!(profileName ?? "").isEmpty, "The thumbnail omitted its embedded profile name.")
        return SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined()
    }

    private static func fileDigest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw ThumbnailFailure(message: message) }
    }
}

private struct ThumbnailFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
#endif
