import Foundation

extension DarktablePhotoEngine {
    func modules() async throws -> [ProcessingModule] {
        if let moduleList { return moduleList }
        let result: [ModuleWireDescriptor] = try await query("modules", input: ModuleWireQuery())
        let descriptors = result.map(\.descriptor).sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        guard Set(descriptors.map(\.operation)).count == descriptors.count,
              descriptors.allSatisfy({ !$0.operation.isEmpty }) else {
            throw PhotoEngineError.invalidOutput("darktable module identities are invalid.")
        }
        moduleList = descriptors
        return descriptors
    }

    func schema(for operation: String) async throws -> ModuleSchema {
        if let cached = moduleSchemas[operation] { return cached }
        let result: ModuleWireSchema = try await query("schema", input: ModuleWireQuery(operation: operation))
        let schema = result.schema
        guard schema.operation == operation, schema.parametersSize > 0,
              schema.fields.allSatisfy({ $0.offset >= 0 && $0.offset < schema.parametersSize }),
              Set(schema.fields.map(\.name)).count == schema.fields.count else {
            throw PhotoEngineError.invalidOutput("darktable parameter schema is invalid.")
        }
        moduleSchemas[operation] = schema
        return schema
    }

    func parameters(for module: ModuleState) async throws -> [String: ModuleParameterValue] {
        let result: ModuleWireValues = try await query("decode", input: ModuleWireQuery(
            operation: module.operation, version: module.version, parameters: module.parameters
        ))
        return result.fields
    }

    func updating(module: ModuleState, values: [String: ModuleParameterValue]) async throws -> ModuleState {
        let result: ModuleWireUpdate = try await query("encode", input: ModuleWireQuery(
            operation: module.operation, version: module.version, parameters: module.parameters, values: values
        ))
        guard result.parameters.count == module.parameters.count else {
            throw PhotoEngineError.invalidOutput("darktable returned a different module parameter size.")
        }
        var updated = module
        updated.parameters = result.parameters
        return updated
    }
}
