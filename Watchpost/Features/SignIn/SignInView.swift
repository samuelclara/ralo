import SwiftUI

struct SignInView: View {
    @Environment(AppModel.self) private var app
    @State private var model = SignInModel()
    @FocusState private var focus: Field?

    private enum Field { case email, password, code }

    var body: some View {
        ZStack {
            LightField()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if let notice = app.notice, model.step == .credentials {
                        Text(notice)
                            .font(.ag(14))
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    switch model.step {
                    case .credentials: credentials
                    case .chooseMethod: methods
                    case .enterCode: codeEntry
                    case .waitingForApproval: approval
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.ag(14))
                            .foregroundStyle(AG.signal)
                            .accessibilityLabel("Error: \(error)")
                    }
                    privacyNote
                }
                .padding(.horizontal, 20)
                .padding(.top, 72)
                .padding(.bottom, 40)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .animation(.snappy, value: model.step)
        .onAppear {
            if model.email.isEmpty, let email = app.lastEmail {
                model.email = email
                focus = .password
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppMark(size: 48)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.ag(40, .regular, relativeTo: .largeTitle))
                    .tracking(-1.2)
                Text(subtitle)
                    .font(.ag(15))
                    .foregroundStyle(AG.ink800)
            }
        }
    }

    private var title: String {
        switch model.step {
        case .credentials: return "Your cameras, calm."
        case .chooseMethod: return "Verify it's you"
        case .enterCode: return "Enter the code"
        case .waitingForApproval: return "Approve the sign-in"
        }
    }

    private var subtitle: String {
        switch model.step {
        case .credentials: return "Sign in with your Arlo account."
        case .chooseMethod: return "Arlo needs a second check. Where should it send a code?"
        case .enterCode: return "Arlo sent a code to \(model.chosen?.nickname ?? "you")."
        case .waitingForApproval: return "Open the Arlo app on your phone and approve this sign-in."
        }
    }

    private var credentials: some View {
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                TextField("Email", text: $model.email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                    .padding(.vertical, 14)
                Divider().overlay(AG.hairline)
                SecureField("Password", text: $model.password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { Task { await submitCredentials() } }
                    .padding(.vertical, 14)
            }
            .font(.ag(17))
            .agCard(padding: 16)

            Toggle(isOn: $model.staySignedIn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stay signed in").font(.ag(15, .medium))
                    Text("Ralo keeps your password behind \(AppLock.biometryName) and renews Arlo's sign-in by itself.")
                        .font(.ag(12))
                        .foregroundStyle(AG.stone500)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(AG.ink950)
            .agCard(padding: 16)

            Button {
                Task { await submitCredentials() }
            } label: {
                HStack {
                    if model.isBusy { ProgressView().tint(.white) }
                    Text("Sign in")
                }
                .font(.ag(17, .semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.glassProminent)
            .tint(AG.ink950)
            .disabled(!model.canSubmitCredentials)
        }
    }

    private var methods: some View {
        VStack(spacing: 12) {
            ForEach(model.options) { option in
                Button {
                    Task { await choose(option) }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: option.symbol)
                            .font(.system(size: 18))
                            .frame(width: 40, height: 40)
                            .background(AG.paper, in: Circle())
                        Text(option.label)
                            .font(.ag(16, .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .foregroundStyle(AG.stone500)
                    }
                    .foregroundStyle(AG.ink950)
                    .agCard(padding: 14)
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
            }
            Button("Use a different account") { model.startOver() }
                .font(.ag(15, .medium))
                .foregroundStyle(AG.ink950)
                .padding(.top, 4)
        }
    }

    private var codeEntry: some View {
        VStack(spacing: 14) {
            TextField("6-digit code", text: $model.code)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .font(.ag(28, .medium))
                .multilineTextAlignment(.center)
                .focused($focus, equals: .code)
                .agCard(padding: 16)
                .onAppear { focus = .code }

            Button {
                Task { await submitCode() }
            } label: {
                HStack {
                    if model.isBusy { ProgressView().tint(.white) }
                    Text("Verify")
                }
                .font(.ag(17, .semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.glassProminent)
            .tint(AG.ink950)
            .disabled(!model.canSubmitCode)

            Button("Start over") { model.startOver() }
                .font(.ag(15, .medium))
                .foregroundStyle(AG.ink950)
        }
    }

    private var approval: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .agCard()
            Button("Start over") { model.startOver() }
                .font(.ag(15, .medium))
                .foregroundStyle(AG.ink950)
        }
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.staySignedIn {
                Label("Your password goes only to Arlo and stays on this device.", systemImage: "lock")
            } else {
                Label("Your password goes only to Arlo and is never stored.", systemImage: "lock")
            }
            Label("Your sign-in stays on this device, behind \(AppLock.biometryName).", systemImage: "faceid")
            Label("Ralo isn't made by Arlo.", systemImage: "info.circle")
        }
        .font(.ag(13))
        .foregroundStyle(AG.ink800)
        .padding(.top, 8)
    }

    // MARK: Actions

    private func submitCredentials() async {
        focus = nil
        if let signIn = await model.submitCredentials(vault: app.vault) {
            app.completeSignIn(signIn)
        }
    }

    private func choose(_ option: TwoFactorOption) async {
        if let signIn = await model.choose(option) {
            app.completeSignIn(signIn)
        }
    }

    private func submitCode() async {
        focus = nil
        if let signIn = await model.submitCode() {
            app.completeSignIn(signIn)
        }
    }
}
