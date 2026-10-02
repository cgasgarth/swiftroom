import Foundation

struct EngineRuntime: Sendable {
    let executable: URL
    let dataDirectory: URL
    let moduleDirectory: URL

    static func locate() -> EngineRuntime? {
        let environment = ProcessInfo.processInfo.environment
        let engineRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            environment["NATIVE_PHOTO_HELPER"].map { URL(fileURLWithPath: $0) },
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("native-photo-helper"),
            engineRoot.appendingPathComponent("Build/MacOS/native-photo-helper")
        ].compactMap { $0 }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            return nil
        }
        let resources = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let packaged = resources.appendingPathComponent("share/darktable")
        let installedPath = environment["NATIVE_PHOTO_DARKTABLE_BUNDLE"] ?? "/Applications/darktable.app"
        let installed = URL(fileURLWithPath: installedPath)
            .appendingPathComponent("Contents/Resources")
        let root = FileManager.default.fileExists(atPath: packaged.path) ? resources : installed
        return EngineRuntime(
            executable: executable,
            dataDirectory: root.appendingPathComponent("share/darktable"),
            moduleDirectory: root.appendingPathComponent("lib/darktable")
        )
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
