import Foundation

enum BezierPreservation {
    static func modules(original: EditState, updated: EditState, target: UUID) throws {
        try BezierIntegration.require(original.modules.count == updated.modules.count, "module count changed")
        for module in original.modules {
            guard let changed = updated.modules.first(where: { $0.id == module.id }) else {
                throw PhotoEngineError.invalidOutput("module identity lost")
            }
            if module.id != target {
                try BezierIntegration.require(changed == module, "unrelated module or order changed")
                continue
            }
            var unchanged = changed
            unchanged.blendParameters = module.blendParameters
            try BezierIntegration.require(unchanged == module, "target module fields changed")
            guard let before = module.blendParameters, let after = changed.blendParameters else {
                throw PhotoEngineError.invalidOutput("missing blend seed")
            }
            let allowed = Set(Array(16..<20) + Array(24..<28))
            try BezierIntegration.require(before.count == after.count && before.indices.allSatisfy {
                allowed.contains($0) || before[$0] == after[$0]
            }, "unrelated blend seed bytes changed")
        }
    }

    static func cancel(
        _ engine: any MaskEditingEngine, source: URL, root: URL, edits: EditState
    ) async throws {
        let accepted = try await engine.maskState(sourceURL: source, edits: edits)
        let task = Task {
            try await engine.applyingMasks(sourceURL: source, edits: edits,
                                           edit: MaskEdit(mutations: [.update(id: 84001, name: "Cancelled")]))
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do {
            _ = try await task.value
            throw PhotoEngineError.invalidOutput("cancelled Bezier mutation accepted")
        } catch is CancellationError { }
        let unchanged = try await engine.maskState(sourceURL: source, edits: edits)
        try BezierIntegration.require(unchanged == accepted, "cancellation changed accepted state")
        let requests = root.appendingPathComponent("Requests")
        try BezierIntegration.require(try FileManager.default.contentsOfDirectory(atPath: requests.path).isEmpty,
                                      "request scratch leaked")
    }
}
