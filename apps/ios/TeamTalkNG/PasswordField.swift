import SwiftUI

/// A password with its "Show password" switch (as the old TeamTalk NG
/// app): hidden by default, shown as plain text while the switch is on.
/// TeamTalk keeps its passwords as plain text anyway. In alerts (which can
/// only hold text fields) passwords are plain TextFields instead.
struct PasswordField: View {
    let label: String
    @Binding var text: String
    /// The switch's name, when a screen has more than one password.
    var showLabel = "Show password"
    var contentType: UITextContentType? = nil
    @State private var shown = false

    init(_ label: String, text: Binding<String>, showLabel: String = "Show password", contentType: UITextContentType? = nil) {
        self.label = label
        _text = text
        self.showLabel = showLabel
        self.contentType = contentType
    }

    var body: some View {
        Group {
            if shown {
                TextField(label, text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                SecureField(label, text: $text)
            }
        }
        .accessibilityLabel(label)
        .textContentType(contentType)
        Toggle(showLabel, isOn: $shown)
    }
}
