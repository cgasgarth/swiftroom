import Foundation

extension DarktablePhotoEngine: MaskEditingEngine {
    func maskState(sourceURL: URL, edits: EditState) async throws -> MaskState {
        let result = try await execute(sourceURL: sourceURL, edits: edits, maximumDimension: 0, command: "prepare")
        defer { try? FileManager.default.removeItem(at: result.directory) }
        try Task.checkCancellation()
        return try result.response.maskState.state(modules: maskModules(result.response.modules, accepted: edits))
    }

    func applyingMasks(sourceURL: URL, edits: EditState, edit: MaskEdit) async throws -> PreparedPhoto {
        let wire = try MaskWireEdit(edit: edit, modules: edits.modules)
        let result = try await execute(
            sourceURL: sourceURL, edits: edits, maximumDimension: 0, command: "prepare", maskEdit: wire
        )
        defer { try? FileManager.default.removeItem(at: result.directory) }
        try Task.checkCancellation()
        var prepared = edits
        prepared.modules = maskModules(result.response.modules, accepted: edits)
        prepared.darktableXMP = result.response.darktableXMP
        prepared.exposureEV = 0
        prepared.temperature = nil
        prepared.tint = 0
        _ = try result.response.maskState.state(modules: prepared.modules)
        return PreparedPhoto(metadata: result.response.metadata, edits: prepared)
    }

    private func maskModules(_ modules: [HelperWireModule], accepted: EditState) -> [ModuleState] {
        modules.map { module in
            var state = module.state
            if let original = accepted.modules.first(where: {
                $0.operation == state.operation && $0.instance == state.instance
            }) { state.id = original.id }
            return state
        }
    }
}
