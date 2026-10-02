import SwiftUI

@MainActor
struct MaskNumericControl: View {
    let title: String
    let fieldID: String
    let range: ClosedRange<Double>
    @Binding var value: Double
    var onValidity: (String, Bool) -> Void
    @State private var entry = ""
    @State private var isValid = true
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer(minLength: 8)
                TextField(title, text: $entry)
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .monospacedDigit().frame(width: 108).focused($isFocused)
                    .accessibilityIdentifier("masks.value.\(fieldID)")
                    .onSubmit(commit).onExitCommand(perform: discard)
            }
            Slider(value: Binding(get: { value }, set: setSlider), in: range)
                .accessibilityLabel(title).accessibilityIdentifier("masks.slider.\(fieldID)")
            if !isValid {
                Text("Enter a finite value from \(format(range.lowerBound)) to \(format(range.upperBound)).")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { entry = format(value); validate(updateValue: false) }
        .onChange(of: entry) { _, _ in if isFocused { validate(updateValue: true) } }
        .onChange(of: value) { _, newValue in
            if !isFocused { entry = format(newValue); validate(updateValue: false) }
        }
        .onChange(of: isFocused) { _, focused in if !focused { commit() } }
    }

    private func format(_ number: Double) -> String {
        number.formatted(.number.grouping(.never).precision(.significantDigits(1...17)))
    }

    private func validate(updateValue: Bool) {
        let parsed = try? Double(entry, format: .number.locale(.current), lenient: false)
        isValid = parsed.map { $0.isFinite && range.contains($0) } ?? false
        onValidity(fieldID, isValid)
        if updateValue, isValid, let parsed { value = parsed }
    }

    private func commit() {
        validate(updateValue: true)
        if isValid { entry = format(value) }
    }
    private func discard() {
        entry = format(value)
        isValid = true
        onValidity(fieldID, true)
    }
    private func setSlider(_ number: Double) {
        value = number
        entry = format(number)
        isValid = true
        onValidity(fieldID, true)
    }
}
