import Foundation

enum MaskFailures {
    static func check(
        _ engine: any MaskEditingEngine, source: URL, edits: EditState, moduleID: UUID
    ) async throws -> Int {
        let invalid: [MaskEdit] = [
            MaskEdit(mutations: [.delete(id: 82001)]),
            MaskEdit(mutations: [.update(id: 82004, geometry: .group([
                MaskGroupMember(maskID: 82004, opacity: 1, operation: .union)
            ]))]),
            MaskEdit(mutations: [.update(id: 82001, geometry: .circle(CircleMask(
                center: MaskPoint(horizontal: 0.5, vertical: 0.5), radius: -1, feather: 0
            )))]),
            MaskEdit(mutations: [.update(id: 81999, geometry: MaskIntegration.definitions[0].geometry)]),
            MaskEdit(mutations: [.create(MaskIntegration.definitions[0])]),
            MaskEdit(mutations: [.delete(id: 1234)]),
            MaskEdit(blends: [ModuleBlendMutation(moduleID: moduleID, patch: BlendPatch(opacity: 101))]),
            MaskEdit(blends: [ModuleBlendMutation(moduleID: moduleID, patch: BlendPatch(maskID: 82001))]),
            MaskEdit(blends: [ModuleBlendMutation(moduleID: moduleID, patch: BlendPatch(
                maskMode: [.enabled, .drawn, .raster]
            ))])
        ]
        for edit in invalid {
            do {
                _ = try await engine.applyingMasks(sourceURL: source, edits: edits, edit: edit)
                throw PhotoEngineError.invalidOutput("invalid mask mutation was accepted")
            } catch PhotoEngineError.processing { continue }
        }
        let accepted = try await engine.maskState(sourceURL: source, edits: edits)
        try MaskIntegration.assert(accepted.forms.count == 7, "rejected mutation corrupted accepted state")
        let task = Task { try await engine.applyingMasks(sourceURL: source, edits: edits,
            edit: MaskEdit(mutations: [.update(id: 82001, name: "Cancelled")])) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do {
            _ = try await task.value
            throw PhotoEngineError.invalidOutput("cancelled mask mutation was accepted")
        } catch is CancellationError { }
        return invalid.count
    }
}
