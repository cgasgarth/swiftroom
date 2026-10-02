import Foundation

struct MaskForm: Codable, Equatable, Identifiable, Sendable {
    var id: Int32
    var type: Int
    var version: Int
    var name: String
    var source: MaskPoint
    var geometry: MaskGeometry?
    var pointData: Data
}

struct MaskState: Equatable, Sendable {
    var forms: [MaskForm]
    var blends: [BlendState]
    var coordinateSpace: MaskCoordinateSpace { .normalizedInput }
}

enum MaskCoordinateSpace: Sendable {
    case normalizedInput
}

struct MaskDefinition: Equatable, Sendable {
    var id: Int32
    var name: String
    var geometry: MaskGeometry
}

enum MaskMutation: Equatable, Sendable {
    case create(MaskDefinition)
    case update(id: Int32, name: String? = nil, geometry: MaskGeometry? = nil)
    case delete(id: Int32)
}

struct MaskEdit: Equatable, Sendable {
    var mutations: [MaskMutation] = []
    var blends: [ModuleBlendMutation] = []
}

protocol MaskEditingEngine: PhotoEngine {
    func maskState(sourceURL: URL, edits: EditState) async throws -> MaskState
    func applyingMasks(sourceURL: URL, edits: EditState, edit: MaskEdit) async throws -> PreparedPhoto
}
