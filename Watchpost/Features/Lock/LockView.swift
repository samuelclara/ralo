import SwiftUI

struct LockView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            LightField()
            VStack(spacing: 28) {
                Spacer()
                AppMark(size: 72)
                VStack(spacing: 8) {
                    Text("Ralo is locked")
                        .font(.ag(30, .medium, relativeTo: .title))
                    Text("Unlock with \(AppLock.biometryName) to see your cameras.")
                        .font(.ag(15))
                        .foregroundStyle(AG.ink800)
                        .multilineTextAlignment(.center)
                }
                if let notice = app.notice {
                    Text(notice)
                        .font(.ag(14))
                        .foregroundStyle(AG.signal)
                        .multilineTextAlignment(.center)
                }
                Spacer()
                Button {
                    Task { await app.unlock() }
                } label: {
                    Label("Unlock", systemImage: "faceid")
                        .font(.ag(17, .semibold))
                        .frame(maxWidth: 320, minHeight: 50)
                }
                .buttonStyle(.glassProminent)
                .tint(AG.ink950)
                .disabled(app.isUnlocking)
                .padding(.bottom, 32)
            }
            .padding(.horizontal, 24)
        }
        .task {
            if !app.suppressAutoUnlock { await app.unlock() }
        }
    }
}
