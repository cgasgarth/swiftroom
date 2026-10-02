import Foundation

struct MaskWireState: Decodable, Sendable {
    var forms: [MaskForm]
    var blends: [BlendWireState]

    func state(modules: [ModuleState]) throws -> MaskState {
        guard Set(forms.map(\.id)).count == forms.count, forms.allSatisfy({ $0.id > 0 }) else {
            throw PhotoEngineError.invalidOutput("darktable returned invalid mask identities.")
        }
        let decoded = try blends.map { blend in
            guard let module = modules.first(where: {
                $0.operation == blend.operation && $0.instance == blend.instance
            }), module.blendParameters == blend.parameters, module.blendVersion == blend.version else {
                throw PhotoEngineError.invalidOutput("darktable returned inconsistent blend state.")
            }
            return BlendState(
                moduleID: module.id, version: blend.version, colorSpace: blend.colorSpace,
                mode: blend.mode, opacity: blend.opacity, maskMode: blend.maskMode, maskID: blend.maskID,
                maskCombine: blend.maskCombine, parameters: blend.parameters,
                supportsDrawnMasks: blend.supportsDrawnMasks
            )
        }
        return MaskState(forms: forms, blends: decoded)
    }
}

struct BlendWireState: Decodable, Sendable {
    var operation: String
    var instance: Int
    var version: Int
    var colorSpace: Int
    var mode: UInt32
    var opacity: Double
    var maskMode: BlendMaskMode
    var maskID: Int32
    var maskCombine: UInt32
    var parameters: Data
    var supportsDrawnMasks: Bool
}

struct MaskWireEdit: Encodable, Sendable {
    var mutations: [MaskWireMutation]
    var blends: [BlendWireMutation]

    init(edit: MaskEdit, modules: [ModuleState]) throws {
        mutations = edit.mutations.map(MaskWireMutation.init)
        guard Set(edit.blends.map(\.moduleID)).count == edit.blends.count else {
            throw PhotoEngineError.unsupported("Patch each module blend once per mask edit.")
        }
        blends = try edit.blends.map { mutation in
            guard let module = modules.first(where: { $0.id == mutation.moduleID }),
                  let seed = module.blendParameters, module.blendVersion == 14 else {
                throw PhotoEngineError.unsupported("Blend editing requires an accepted version 14 parameter seed.")
            }
            return BlendWireMutation(
                operation: module.operation, instance: module.instance,
                version: 14, seed: seed, patch: mutation.patch
            )
        }
    }
}

struct MaskWireMutation: Encodable, Sendable {
    var action: String
    var id: Int32
    var name: String?
    var geometry: MaskGeometry?

    init(_ mutation: MaskMutation) {
        switch mutation {
        case .create(let form):
            action = "create"
            id = form.id
            name = form.name
            geometry = form.geometry
        case .update(let identifier, let label, let shape):
            action = "update"
            id = identifier
            name = label
            geometry = shape
        case .delete(let identifier):
            action = "delete"
            id = identifier
        }
    }
}

struct BlendWireMutation: Encodable, Sendable {
    var operation: String
    var instance: Int
    var version: Int
    var seed: Data
    var patch: BlendPatch
}
