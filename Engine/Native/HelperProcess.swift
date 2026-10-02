import Darwin
import Foundation

actor HelperProcess {
    private var processes: [UUID: Process] = [:]

    func run(executable: URL, arguments: [String], logURL: URL) async throws {
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                do {
                    _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
                    let log = try FileHandle(forWritingTo: logURL)
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    process.standardOutput = log
                    process.standardError = log
                    process.terminationHandler = { process in
                        let status = process.terminationStatus
                        Task {
                            await self.complete(identifier, status: status, log: log, continuation: continuation)
                        }
                    }
                    processes[identifier] = process
                    do {
                        try process.run()
                    } catch {
                        processes.removeValue(forKey: identifier)
                        try? log.close()
                        continuation.resume(throwing: error)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancel(identifier) }
        }
    }

    private func complete(
        _ identifier: UUID, status: Int32, log: FileHandle,
        continuation: CheckedContinuation<Void, Error>
    ) {
        processes.removeValue(forKey: identifier)
        try? log.close()
        if status == 0 {
            continuation.resume()
        } else {
            continuation.resume(throwing: PhotoEngineError.processing("darktable helper exited with status \(status)."))
        }
    }

    private func cancel(_ identifier: UUID) async {
        guard let process = processes[identifier], process.isRunning else { return }
        process.terminate()
        try? await Task.sleep(for: .milliseconds(300))
        if let running = processes[identifier], running.isRunning {
            _ = Darwin.kill(running.processIdentifier, SIGKILL)
        }
    }
}
