import SwiftUI

// Controls written once so VoiceOver gets them right everywhere (the
// owner's rules): a slider says its name once; numbers are typed into a
// field, never stepped; every field says what it's for.

/// A slider with its name shown above it, which VoiceOver hears once (as
/// the slider's name, with its value).
struct NamedSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    let spoken: String

    init(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 1, spoken: String) {
        self.label = label
        _value = value
        self.range = range
        self.step = step
        self.spoken = spoken
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).accessibilityHidden(true)
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(label)
                .accessibilityValue(spoken)
        }
    }
}

extension NamedSlider {
    /// An Int-valued slider (percentages and such).
    init(_ label: String, int: Binding<Int>, in range: ClosedRange<Int>, spoken: String) {
        self.init(label, value: Binding(get: { Double(int.wrappedValue) }, set: { int.wrappedValue = Int($0) }),
                  in: Double(range.lowerBound)...Double(range.upperBound), step: 1, spoken: spoken)
    }
}

/// A number typed into a field (kept within its range), with its name.
struct NumberField: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    @State private var text = ""
    @FocusState private var focused: Bool

    init(_ label: String, value: Binding<Int>, in range: ClosedRange<Int>) {
        self.label = label
        _value = value
        self.range = range
    }

    var body: some View {
        LabeledContent(label) {
            TextField(label, text: $text)
                .keyboardType(range.lowerBound < 0 ? .numbersAndPunctuation : .numberPad)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { if !focused { commit() } }
                .accessibilityLabel(label)
                .accessibilityHint("Between \(range.lowerBound) and \(range.upperBound).")
        }
        .onAppear { text = String(value) }
        .onChange(of: value) { if !focused { text = String(value) } }
    }

    private func commit() {
        if let n = Int(text.trimmingCharacters(in: .whitespaces)) {
            value = min(range.upperBound, max(range.lowerBound, n))
        }
        text = String(value)
    }
}

extension NumberField {
    /// An Int32 number.
    init(_ label: String, int32: Binding<Int32>, in range: ClosedRange<Int>) {
        self.init(label, value: Binding(get: { Int(int32.wrappedValue) }, set: { int32.wrappedValue = Int32($0) }), in: range)
    }
}
