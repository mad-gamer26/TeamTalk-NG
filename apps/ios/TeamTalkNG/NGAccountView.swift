import SwiftUI

/// Settings → NG Account.
struct NGAccountView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let account = model.account
        Group {
            if let email = account.email {
                SignedInView(email: email)
            } else {
                SignInView()
            }
        }
        .navigationTitle("NG Account")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SignedInView: View {
    @Environment(AppModel.self) private var model
    let email: String
    @State private var confirmSignOut = false
    @State private var changing = false

    var body: some View {
        let account = model.account
        Form {
            Section {
                LabeledContent("Signed in as", value: email)
            } footer: {
                Text("Your NG Account is for publishing sound packs: packs you publish stay yours to update or withdraw, on any device and after reinstalling the app. Your servers and settings sync through iCloud (Settings → iCloud sync).")
            }
            Section {
                Button("Change password") { changing = true }
                Button("Sign out", role: .destructive) { confirmSignOut = true }
            }
        }
        .confirmationDialog("Sign out of NG Account?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await account.signOut() } }
        } message: {
            Text("Packs you published stay in the catalog. Sign in again to update or withdraw them.")
        }
        .sheet(isPresented: $changing) { ChangePasswordView() }
    }
}

private struct ChangePasswordView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                PasswordField("Current password", text: $current, showLabel: "Show current password", contentType: .password)
                PasswordField("New password", text: $new, showLabel: "Show new password", contentType: .newPassword)
                if let problem { Text(problem) }
            }
            .navigationTitle("Change password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Change") {
                        busy = true
                        Task {
                            problem = await model.account.changePassword(current: current, new: new)
                            busy = false
                            if problem == nil { announce("Password changed"); dismiss() } else { announce(problem!) }
                        }
                    }
                    .disabled(busy || current.isEmpty || new.isEmpty)
                }
            }
        }
    }
}

private struct SignInView: View {
    @Environment(AppModel.self) private var model
    enum Mode: String, CaseIterable, Identifiable {
        case signIn = "Sign in", make = "Make an account"
        var id: Self { self }
    }
    enum Step { case form, code, forgot, reset }

    @State private var mode = Mode.signIn
    @State private var step = Step.form
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        Form {
            switch step {
            case .form:
                Picker("", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Sign in or make an account")
                Section {
                    emailField
                    PasswordField("Password", text: $password)
                        .textContentType(mode == .signIn ? .password : .newPassword)
                }
                Section {
                    Button(mode == .signIn ? "Sign in" : "Make the account") { submit() }
                        .disabled(busy || email.isEmpty || password.isEmpty)
                    if mode == .signIn {
                        Button("Forgot password") { problem = nil; step = .forgot }
                    }
                }
            case .code:
                Section {
                    Text("We emailed a code to \(email). Type it here to finish making your account.")
                    codeField
                    Button("Finish") { submit() }.disabled(busy || code.isEmpty)
                    Button("Start again") { step = .form; code = "" }
                }
            case .forgot:
                Section {
                    Text("We'll email you a code for choosing a new password.")
                    emailField
                    Button("Email me a code") { submit() }.disabled(busy || email.isEmpty)
                    Button("Back") { step = .form }
                }
            case .reset:
                Section {
                    Text("Type the code we emailed to \(email), and your new password.")
                    codeField
                    PasswordField("New password", text: $password, contentType: .newPassword)
                    Button("Set password and sign in") { submit() }.disabled(busy || code.isEmpty || password.isEmpty)
                    Button("Back") { step = .form }
                }
            }
            if let problem {
                Section { Text(problem) }
            }
            if step == .form {
                Section {
                    Text("An NG Account is only for publishing sound packs to the catalog. Your servers and settings sync through iCloud.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: mode) { problem = nil }
    }

    private var emailField: some View {
        TextField("Email", text: $email).accessibilityLabel("Email")
            .textContentType(.emailAddress)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    private var codeField: some View {
        TextField("Code", text: $code).accessibilityLabel("Code")
            .textContentType(.oneTimeCode)
            .keyboardType(.numberPad)
    }

    private func submit() {
        busy = true
        problem = nil
        let account = model.account
        Task {
            let result: String?
            switch step {
            case .form:
                if mode == .signIn {
                    result = await account.signIn(email: email, password: password)
                } else {
                    result = await account.signUp(email: email, password: password)
                    if result == nil { step = .code; announce("Code sent. Check your email.") }
                }
            case .code:
                result = await account.verify(email: email, code: code)
            case .forgot:
                result = await account.forgotPassword(email: email)
                if result == nil { password = ""; step = .reset; announce("Code sent. Check your email.") }
            case .reset:
                result = await account.resetPassword(email: email, code: code, password: password)
            }
            busy = false
            problem = result
            if let result { announce(result) } else if account.signedIn { announce("Signed in to NG Account") }
        }
    }
}
