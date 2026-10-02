import CryptoKit
import Foundation

struct EngineRuntime: Sendable {
    let executable: URL
    let dataDirectory: URL
    let moduleDirectory: URL

    static func locate() throws -> EngineRuntime {
        let environment = ProcessInfo.processInfo.environment
        let engineRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            environment["NATIVE_PHOTO_HELPER"].map { URL(fileURLWithPath: $0) },
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("native-photo-helper"),
            engineRoot.appendingPathComponent("Build/MacOS/native-photo-helper")
        ].compactMap { $0 }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw PhotoEngineError.unavailable("Build the darktable helper before opening a photo.")
        }
        let resources = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let packaged = resources.appendingPathComponent("share/darktable")
        let installedPath = environment["NATIVE_PHOTO_DARKTABLE_BUNDLE"] ?? "/Applications/darktable.app"
        let installed = URL(fileURLWithPath: installedPath)
            .appendingPathComponent("Contents/Resources")
        let root = FileManager.default.fileExists(atPath: packaged.path) ? resources : installed
        let runtime = EngineRuntime(
            executable: executable,
            dataDirectory: root.appendingPathComponent("share/darktable"),
            moduleDirectory: root.appendingPathComponent("lib/darktable")
        )
        try runtime.validate()
        return runtime
    }

    func validate() throws {
        let linkedLibrary = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/lib/darktable/libdarktable.dylib")
        let libraries = Set([linkedLibrary, moduleDirectory.appendingPathComponent("libdarktable.dylib")]
            .map { $0.resolvingSymlinksInPath().standardizedFileURL })
        for library in libraries {
            guard let data = try? Data(contentsOf: library, options: .mappedIfSafe),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
                == "922a2d075e8c59d0e9d7f27e73e80cab1a39f3bf64a5ba470ce19b86945fa8db" else {
                throw PhotoEngineError.unavailable("The darktable runtime differs from the verified 5.6.0 build.")
            }
        }
    }

    func arguments(command: String, request: URL, response: URL, directory: URL) -> [String] {
        [command, request.path, response.path, "native-photo",
         "--configdir", directory.appendingPathComponent("config").path,
         "--cachedir", directory.appendingPathComponent("cache").path,
         "--library", directory.appendingPathComponent("library.db").path,
         "--datadir", dataDirectory.path, "--moduledir", moduleDirectory.path,
         "--conf", "write_sidecar_files=never", "--conf", "opencl=FALSE"]
    }
}
