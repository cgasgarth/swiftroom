import Foundation

extension ModuleParameterField {
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return name.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var isInteger: Bool {
        switch kind {
        case .int, .uint, .int8, .uint8, .short, .ushort: true
        case .float, .double, .bool, .enumeration, .other: false
        }
    }

    var isNumeric: Bool {
        isInteger || kind == .float || kind == .double
    }

    var boundsDescription: String? {
        if let minimum, let maximum {
            return "Range \(ModuleParameterValue.number(minimum).entryText) … "
                + ModuleParameterValue.number(maximum).entryText
        }
        if let minimum { return "Minimum \(ModuleParameterValue.number(minimum).entryText)" }
        if let maximum { return "Maximum \(ModuleParameterValue.number(maximum).entryText)" }
        return nil
    }

    func accepts(_ value: ModuleParameterValue) -> Bool {
        switch kind {
        case .bool:
            if case .boolean = value { return true }
            return false
        case .enumeration:
            return choiceValue(for: value) != nil
        case .other: return false
        case .float, .double, .int, .uint, .int8, .uint8, .short, .ushort:
            return validNumber(value)
        }
    }

    func choiceValue(for value: ModuleParameterValue) -> Int? {
        switch value {
        case .integer(let number):
            choices.first { $0.value == number }?.value
        case .text(let name):
            choices.first { $0.name == name }?.value
        case .number, .boolean: nil
        }
    }

    func valuesEqual(_ lhs: ModuleParameterValue, _ rhs: ModuleParameterValue) -> Bool {
        if isNumeric { return lhs.doubleValue != nil && lhs.doubleValue == rhs.doubleValue }
        if kind == .enumeration, let left = choiceValue(for: lhs), let right = choiceValue(for: rhs) {
            return left == right
        }
        return lhs == rhs
    }

    func parsedValue(_ text: String) -> ModuleParameterValue? {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = stripped.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
        if isInteger {
            guard let number = Int(normalized) else { return nil }
            let value = ModuleParameterValue.integer(number)
            return accepts(value) ? value : nil
        }
        guard isNumeric, let number = Double(normalized) else { return nil }
        let value = ModuleParameterValue.number(number)
        return accepts(value) ? value : nil
    }

    func sliderRange(for value: ModuleParameterValue) -> ClosedRange<Double>? {
        guard let minimum, let maximum, minimum.isFinite, maximum.isFinite,
            minimum < maximum, maximum - minimum <= 100_000,
            let current = value.doubleValue, (minimum...maximum).contains(current)
        else { return nil }
        return minimum...maximum
    }

    private func validNumber(_ value: ModuleParameterValue) -> Bool {
        if isInteger {
            guard case .integer = value else { return false }
        }
        guard let number = value.doubleValue, number.isFinite else { return false }
        if let minimum, number < minimum { return false }
        if let maximum, number > maximum { return false }
        return represents(number)
    }

    private func represents(_ number: Double) -> Bool {
        switch kind {
        case .float: return abs(number) <= Double(Float.greatestFiniteMagnitude)
        case .int: return Int32(exactly: number) != nil
        case .uint: return UInt32(exactly: number) != nil
        case .int8: return Int8(exactly: number) != nil
        case .uint8: return UInt8(exactly: number) != nil
        case .short: return Int16(exactly: number) != nil
        case .ushort: return UInt16(exactly: number) != nil
        case .double: return true
        case .bool, .enumeration, .other: return false
        }
    }
}

extension ModuleParameterValue {
    var entryText: String {
        switch self {
        case .number(let number): String(number)
        case .integer(let number): String(number)
        case .boolean(let value): value ? "On" : "Off"
        case .text(let value): value
        }
    }
}
