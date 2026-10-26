import SwiftUI

struct SettingsView: View {
    let store: CameraStore

    @Environment(AppModel.self) private var app
    @AppStorage(PreferenceKey.lockDelay) private var lockDelay = AppLock.LockDelay.immediately.rawValue
    @State private var confirmSignOut = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                section("Security") {
                    row(icon: "faceid", title: "Locked with \(AppLock.biometryName)",
                        detail: "Your Arlo sign-in only opens after \(AppLock.biometryName).")
                    divider
                    HStack {
                        rowLabel(icon: "timer", title: "Lock", detail: "When you leave the app")
                        Spacer()
                        Picker("Lock", selection: $lockDelay) {
                            ForEach(AppLock.LockDelay.allCases) { delay in
                                Text(delay.label).tag(delay.rawValue)
                            }
                        }
                        .labelsHidden()
                        .tint(AG.ink950)
                    }
                    .padding(.vertical, 10)
                    divider
                    Button {
                        app.lock(manual: true)
                    } label: {
                        rowLabel(icon: "lock", title: "Lock now", detail: nil)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 12)
                }

                section("Account") {
                    row(icon: "person.crop.circle", title: maskedEmail, detail: "Arlo account")
                    divider
                    Toggle(isOn: staySignedIn) {
                        rowLabel(icon: "key", title: "Stay signed in", detail: app.staysSignedIn
                            ? "Renews Arlo's sign-in with your saved password."
                            : "Turn on when you next sign in.")
                    }
                    .tint(AG.ink950)
                    .disabled(!app.staysSignedIn)
                    .padding(.vertical, 10)
                    divider
                    Button(role: .destructive) {
                        confirmSignOut = true
                    } label: {
                        Label("Sign out and forget this device", systemImage: "rectangle.portrait.and.arrow.right")
                            .font(.ag(15, .medium))
                            .foregroundStyle(AG.signal)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 14)
                }

                section("What Ralo keeps") {
                    if app.staysSignedIn {
                        bullet("Your password: in the Keychain with your sign-in, behind \(AppLock.biometryName), so it can be renewed. It only goes to Arlo.")
                    } else {
                        bullet("Your password: never. It goes to Arlo once and is discarded.")
                    }
                    bullet("Your Arlo sign-in: in the Keychain, on this device only, behind \(AppLock.biometryName).")
                    bullet("Snapshots and clips: never saved, except snapshots you choose to add to Photos.")
                    bullet("Battery readings: on this device for 60 days, to predict recharges. Erased when you sign out.")
                    bullet("Analytics or tracking: none. Ralo only talks to Arlo.")
                }

                section("About") {
                    Text("Ralo isn't made by or affiliated with Arlo. It connects the way Arlo's own website and app do, which Arlo can change at any time.")
                        .font(.ag(13))
                        .foregroundStyle(AG.stone500)
                        .padding(.vertical, 12)
                    divider
                    Text("Version \(version) · Urbanist typeface under the SIL Open Font License")
                        .font(.ag(12))
                        .foregroundStyle(AG.stone500)
                        .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(LightField())
        .navigationTitle("Settings")
        .toolbarTitleDisplayMode(.inlineLarge)
        .confirmationDialog("Sign out of Arlo?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task { await app.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your sign-in is erased from this device. You'll need your password and a verification code to sign in again.")
        }
    }

    /// Can only be switched off here: the password isn't known until the next sign-in.
    private var staySignedIn: Binding<Bool> {
        Binding(get: { app.staysSignedIn }, set: { if !$0 { app.stopStayingSignedIn() } })
    }

    private var maskedEmail: String {
        let email = store.accountEmail
        guard let at = email.firstIndex(of: "@"), let first = email.first else { return "Signed in" }
        return "\(first)•••\(email[at...])"
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var divider: some View {
        Rectangle().fill(AG.hairline).frame(height: 1)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.ag(15, .medium))
            VStack(alignment: .leading, spacing: 0, content: content)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white, in: RoundedRectangle(cornerRadius: AG.cardRadius, style: .continuous))
        }
    }

    private func row(icon: String, title: String, detail: String?) -> some View {
        rowLabel(icon: icon, title: title, detail: detail)
            .padding(.vertical, 12)
    }

    private func rowLabel(icon: String, title: String, detail: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .frame(width: 36, height: 36)
                .background(AG.paper, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ag(15, .medium))
                if let detail {
                    Text(detail).font(.ag(12)).foregroundStyle(AG.stone500)
                }
            }
        }
        .foregroundStyle(AG.ink950)
        .contentShape(Rectangle())
    }

    private func bullet(_ text: String) -> some View {
        Label {
            Text(text).font(.ag(14)).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(AG.ink950)
        }
        .padding(.vertical, 10)
    }
}
