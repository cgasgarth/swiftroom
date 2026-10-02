import Foundation

struct ModuleWireDescriptor: Decodable, Sendable {
    var operation: String
    var title: String
    var version: Int
    var hasIntrospection: Bool
    var supportsInstances: Bool
    var supportsBlending: Bool
    var documentationURL: URL?

    enum CodingKeys: String, CodingKey {
        case operation, title, version
        case hasIntrospection = "have_introspection"
        case supportsInstances = "supports_instances"
        case supportsBlending = "supports_blending"
        case documentationURL = "doc_url"
    }

    var descriptor: ProcessingModule {
        ProcessingModule(
            operation: operation, title: title, version: version, hasIntrospection: hasIntrospection,
            supportsInstances: supportsInstances, supportsBlending: supportsBlending,
            documentationURL: documentationURL
        )
    }
}

struct ModuleWireSchema: Decodable, Sendable {
    var operation: String
    var parametersVersion: Int
    var parametersSize: Int
    var fields: [ModuleWireField]

    enum CodingKeys: String, CodingKey {
        case operation, fields
        case parametersVersion = "params_version"
        case parametersSize = "params_size"
    }

    var schema: ModuleSchema {
        ModuleSchema(
            operation: operation, parametersVersion: parametersVersion,
            parametersSize: parametersSize, fields: fields.map(\.field)
        )
    }
}

struct ModuleWireField: Decodable, Sendable {
    var name: String
    var title: String?
    var type: String
    var offset: Int
    var minimum: Double?
    var maximum: Double?
    var defaultValue: ModuleParameterValue?
    var choices: [ModuleParameterChoice]?

    enum CodingKeys: String, CodingKey {
        case name, title, type, offset
        case minimum = "min"
        case maximum = "max"
        case defaultValue = "default"
        case choices = "values"
    }

    var field: ModuleParameterField {
        ModuleParameterField(
            name: name, kind: type == "enum" ? .enumeration : ModuleParameterKind(rawValue: type) ?? .other,
            offset: offset, minimum: minimum, maximum: maximum,
            defaultValue: defaultValue, choices: choices ?? [], title: title
        )
    }
}

struct ModuleWireQuery: Encodable, Sendable {
    var operation: String?
    var version: Int?
    var parameters: Data?
    var values: [String: ModuleParameterValue]?
}

struct ModuleWireValues: Decodable, Sendable {
    var fields: [String: ModuleParameterValue]
}

struct ModuleWireUpdate: Decodable, Sendable {
    var parameters: Data
}
