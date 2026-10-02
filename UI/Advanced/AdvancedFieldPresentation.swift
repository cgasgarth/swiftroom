import Foundation

struct AdvancedFieldPresentation {
    let schema: ModuleSchema
    let values: [String: ModuleParameterValue]

    var fields: [ModuleParameterField] {
        guard hasExposureSemantics, let automatic else { return schema.fields }
        let inactive: Set<String> = automatic
            ? ["exposure", "compensate_exposure_bias", "compensate_hilite_pres"]
            : ["deflicker_percentile", "deflicker_target_level"]
        let order = ["mode", "exposure", "deflicker_percentile", "deflicker_target_level", "black",
            "compensate_exposure_bias", "compensate_hilite_pres"]
        return schema.fields.filter { !inactive.contains($0.name) }.sorted {
            (order.firstIndex(of: $0.name) ?? order.count) < (order.firstIndex(of: $1.name) ?? order.count)
        }
    }

    func unit(for field: ModuleParameterField) -> String? {
        guard hasExposureSemantics else { return nil }
        switch field.name {
        case "exposure", "deflicker_target_level": return "EV"
        case "deflicker_percentile": return "%"
        default: return nil
        }
    }

    func title(for field: ModuleParameterField) -> String {
        guard hasExposureSemantics else { return field.displayTitle }
        switch field.name {
        case "black": return "Black Level"
        case "deflicker_target_level": return "Target Level"
        case "compensate_exposure_bias": return "Camera Bias"
        case "compensate_hilite_pres": return "Highlight Bias"
        default: return field.displayTitle
        }
    }

    var automatic: Bool? {
        guard hasExposureSemantics, let field = schema.fields.first(where: { $0.name == "mode" }),
            let value = values["mode"], let choice = field.choiceValue(for: value) else { return nil }
        switch field.choices.first(where: { $0.value == choice })?.name {
        case "EXPOSURE_MODE_MANUAL": return false
        case "EXPOSURE_MODE_DEFLICKER": return true
        default: return nil
        }
    }

    var hasExposureSemantics: Bool {
        guard schema.operation == "exposure", schema.parametersVersion == 7,
            let mode = schema.fields.first(where: { $0.name == "mode" }) else { return false }
        return mode.choices.contains { $0.name == "EXPOSURE_MODE_MANUAL" }
            && mode.choices.contains { $0.name == "EXPOSURE_MODE_DEFLICKER" }
    }
}

struct AdvancedNumericPresentation {
    let field: ModuleParameterField
    let unit: String?
    init(field: ModuleParameterField, unit: String? = nil) {
        self.field = field
        self.unit = unit
    }

    var unitLabel: String? { unit }

    func text(for value: ModuleParameterValue) -> String {
        guard !field.isInteger, let number = value.doubleValue else { return value.entryText }
        let rounded = (number * 100).rounded() / 100
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), rounded == 0 ? 0 : rounded)
    }

    func preservesFinerValue(_ value: ModuleParameterValue) -> Bool {
        guard !field.isInteger, let number = value.doubleValue else { return false }
        let rounded = (number * 100).rounded() / 100
        return abs(number - rounded) > max(0.000_000_01, abs(number) * 0.000_000_1)
    }

    func parsedValue(_ text: String) -> ModuleParameterValue? {
        if field.isInteger { return field.parsedValue(text) }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
        let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count <= 2, components.last.map({ components.count == 1 || $0.count <= 2 }) == true,
            !normalized.lowercased().contains("e"), let coefficient = Double(normalized), coefficient.isFinite
        else { return nil }
        let value = ModuleParameterValue.number(coefficient)
        return field.accepts(value) ? value : nil
    }

    func cappedEntry(_ text: String) -> String {
        guard !field.isInteger else { return text }
        let separator = Locale.current.decimalSeparator ?? "."
        guard let point = text.range(of: separator) ?? text.range(of: ".") else { return text }
        return String(text[..<point.upperBound]) + String(text[point.upperBound...].prefix(2))
    }

    func roundedValue(_ number: Double) -> ModuleParameterValue? {
        if field.isInteger {
            guard let integer = Int(exactly: number.rounded()) else { return nil }
            let value = ModuleParameterValue.integer(integer)
            return field.accepts(value) ? value : nil
        }
        let rounded = (number * 100).rounded() / 100
        let value = ModuleParameterValue.number(rounded)
        return field.accepts(value) ? value : nil
    }
}
