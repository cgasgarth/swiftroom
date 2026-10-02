import Foundation

struct HelperWireRequest: Encodable, Sendable {
    var source: String
    var xmp: String?
    var edits: EditState
    var destination: String?
    var format: String
    var colorSpace: String
    var maximumDimension: Int
    var quality: Int
}

struct HelperWireResponse: Decodable, Sendable {
    var pixelWidth: Int
    var pixelHeight: Int
    var metadata: PhotoMetadata
    var darktableXMP: Data
    var modules: [HelperWireModule]
}

struct HelperWireModule: Decodable, Sendable {
    var operation: String
    var version: Int
    var instance: Int
    var enabled: Bool
    var order: Double
    var parameters: Data
    var blendParameters: Data?
    var blendVersion: Int?
    var name: String?

    var state: ModuleState {
        ModuleState(
            operation: operation, version: version, instance: instance, enabled: enabled,
            order: order, parameters: parameters, blendParameters: blendParameters,
            blendVersion: blendVersion, name: name
        )
    }
}
