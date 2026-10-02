import CryptoKit
import Foundation

@main
struct ExportSafetySmoke {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixture = URL(fileURLWithPath: CommandLine.arguments[2])
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let originals = root.appendingPathComponent("Originals")
        try manager.createDirectory(at: originals, withIntermediateDirectories: true)
        let original = originals.appendingPathComponent("Source.ARW")
        try manager.copyItem(at: fixture, to: original)
        let hash = try SHA256.hash(data: Data(contentsOf: original))
        let symlink = root.appendingPathComponent("symlink.ARW")
        try manager.createSymbolicLink(at: symlink, withDestinationURL: original)
        let parentAlias = root.appendingPathComponent("Alias")
        try manager.createSymbolicLink(at: parentAlias, withDestinationURL: originals)
        let hardlink = root.appendingPathComponent("hardlink.ARW")
        try manager.linkItem(at: original, to: hardlink)
        let spelling = originals.appendingPathComponent("sOuRcE.aRw")
        let engine = NativePhotoEngineFactory.make(cacheDirectory: root.appendingPathComponent("Cache"))
        let destinations = [original, symlink, parentAlias.appendingPathComponent("Source.ARW"), hardlink, spelling]
        var verified = 0
        for destination in destinations {
            if !manager.fileExists(atPath: destination.path) { continue }
            do {
                _ = try await engine.export(ExportRequest(
                    assetID: UUID(), sourceURL: original, edits: .original, destinationURL: destination,
                    format: .png, colorSpace: .sRGB, quality: 0.95, maximumDimension: 64
                ))
                throw PhotoEngineError.processing("unsafe destination was accepted")
            } catch PhotoEngineError.unsupported { verified += 1 }
        }
        guard verified >= 4, try SHA256.hash(data: Data(contentsOf: original)) == hash else {
            throw PhotoEngineError.processing("export safety integration failed")
        }
        print("Export safety integration passed: \(verified) filesystem aliases rejected; input hash preserved.")
    }
}
