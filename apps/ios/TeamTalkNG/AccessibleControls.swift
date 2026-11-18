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
    /// What VoiceOver says for a value (from the slider's own position).
    let spoken: (Double) -> String

    /// The value just chosen, shown at once until the source catches up.
    /// Many sources (a person's volume, an AudioNet stream's) change only
    /// after a round trip: without this the slider sprang back, VoiceOver
    /// said the old value, and the next swipe started from it again.
    @State private var chosen: Double?
    @State private var settle: Task<Void, Never>?

    init(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 1,
         spoken: @escaping (Double) -> String) {
        self.label = label
        _value = value
        self.range = range
        self.step = step
        self.spoken = spoken
    }

    private var shown: Double { chosen ?? value }

    /// What SwiftUI's Slider can take: since iOS 27 it stops the app when
    /// its range is empty or shorter than its step (a recording's
    /// position before its length is known, a clip under a second).
    private var safeRange: ClosedRange<Double> {
        range.upperBound > range.lowerBound ? range : range.lowerBound...(range.lowerBound + max(step, 1))
    }
    private var safeStep: Double {
        let span = safeRange.upperBound - safeRange.lowerBound
        return step > 0 && step <= span ? step : span
    }

    /// A VoiceOver swipe's step: the slider's own, or a twentieth of its
    /// range when that would take too many swipes (5 on 0 to 100).
    private var swipeStep: Double {
        let span = range.upperBound - range.lowerBound
        guard step > 0, span / step > 20 else { return step }
        let twentieth = span / 20
        return max(step, (twentieth / step).rounded() * step)
    }

    private func set(_ v: Double) {
        let v = min(range.upperBound, max(range.lowerBound, v))
        chosen = v
        value = v
        // If the source never reports it (a failure), show it again after a while.
        settle?.cancel()
        settle = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { chosen = nil }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).accessibilityHidden(true)
            Slider(value: Binding(get: { min(safeRange.upperBound, max(safeRange.lowerBound, shown)) }, set: { set($0) }),
                   in: safeRange, step: safeStep)
                .accessibilityLabel(label)
                .accessibilityValue(spoken(shown))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: set(shown + swipeStep)
                    case .decrement: set(shown - swipeStep)
                    @unknown default: break
                    }
                }
        }
        // The source caught up (or changed elsewhere): it's shown again.
        .onChange(of: value) { if let c = chosen, abs(c - value) < step / 2 || abs(c - value) < 0.0001 { chosen = nil } }
    }
}

extension NamedSlider {
    /// An Int-valued slider (percentages and such).
    init(_ label: String, int: Binding<Int>, in range: ClosedRange<Int>, spoken: @escaping (Int) -> String) {
        self.init(label, value: Binding(get: { Double(int.wrappedValue) }, set: { int.wrappedValue = Int($0.rounded()) }),
                  in: Double(range.lowerBound)...Double(range.upperBound), step: 1, spoken: { spoken(Int($0.rounded())) })
    }
}

/// A switch whose change shows at once, whatever it's bound to: the value
/// just chosen is shown until the source catches up (a connection's
/// state changes after a round trip; without this the switch flipped back
/// and VoiceOver said the old state). Use it for every switch bound to a
/// connection, an AudioNet stream or anything else that isn't local state.
struct LiveToggle: View {
    let label: String
    @Binding var isOn: Bool
    @State private var chosen: Bool?
    @State private var settle: Task<Void, Never>?

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        _isOn = isOn
    }

    var body: some View {
        Toggle(label, isOn: Binding(get: { chosen ?? isOn }, set: { v in
            chosen = v
            isOn = v
            settle?.cancel()
            settle = Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { chosen = nil }
            }
        }))
        .onChange(of: isOn) { if chosen == isOn { chosen = nil } }
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
