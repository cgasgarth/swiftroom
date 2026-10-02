import Foundation

struct ProcessingModule: Codable, Identifiable, Sendable {
    var operation: String
    var title: String
    var version: Int
    var hasIntrospection: Bool
    var supportsInstances: Bool
    var supportsBlending: Bool
    var documentationURL: URL?
    var id: String { operation }
}

enum ModuleParameterKind: String, Codable, Sendable {
    case float, double, int, uint, int8, uint8, short, ushort, bool, enumeration, other
}

enum ModuleParameterValue: Equatable, Sendable {
    case number(Double), integer(Int), boolean(Bool), text(String)

    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .integer(let value): return Double(value)
        case .boolean, .text: return nil
        }
    }
}

extension ModuleParameterValue: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .boolean(value) } else if let value = try? container.decode(Int.self) { self = .integer(value) } else if let value = try? container.decode(Double.self) { self = .number(value) } else { self = .text(try container.decode(String.self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .text(let value): try container.encode(value)
        }
    }
}

struct ModuleParameterChoice: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var value: Int
    var id: Int { value }
}

struct ModuleParameterField: Codable, Identifiable, Sendable {
    var name: String
    var kind: ModuleParameterKind
    var offset: Int
    var minimum: Double?
    var maximum: Double?
    var defaultValue: ModuleParameterValue?
    var choices: [ModuleParameterChoice]
    var id: String { name }
}

struct ModuleSchema: Codable, Sendable {
    var operation: String
    var parametersVersion: Int
    var parametersSize: Int
    var fields: [ModuleParameterField]
}

extension PhotoEngine {
    func modules() async throws -> [ProcessingModule] {
        throw PhotoEngineError.unsupported("This engine does not expose processing module metadata.")
    }

    func schema(for operation: String) async throws -> ModuleSchema {
        throw PhotoEngineError.unsupported("The \(operation) parameter schema is unavailable.")
    }

    func parameters(for module: ModuleState) async throws -> [String: ModuleParameterValue] {
        throw PhotoEngineError.unsupported("The \(module.operation) parameter values are unavailable.")
    }

    func updating(module: ModuleState, values: [String: ModuleParameterValue]) async throws -> ModuleState {
        throw PhotoEngineError.unsupported("The \(module.operation) parameter editor is unavailable.")
    }
}
