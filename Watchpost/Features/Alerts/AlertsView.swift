import SwiftUI

/// What counts as worth flagging inside Ralo. Push notifications stay with Arlo's app,
/// so no server ever holds your Arlo session.
struct AlertsView: View {
    let store: CameraStore

    @AppStorage(PreferenceKey.alertPeople) private var people = true
    @AppStorage(PreferenceKey.alertParcels) private var parcels = true
    @AppStorage(PreferenceKey.alertVehicles) private var vehicles = false
    @AppStorage(PreferenceKey.alertAnimals) private var animals = false
    @AppStorage(PreferenceKey.groupByVisit) private var groupByVisit = true

    private var flaggedToday: Int {
        Visit.group(store.todayClips, byVisit: groupByVisit)
            .filter { Preferences.highlights($0.category) }
            .count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Flagged today").font(.ag(15, .medium))
                    Figure(value: "\(flaggedToday)", unit: "visits", size: 96)
                    Text("Visits that match the types switched on below.")
                        .font(.ag(13))
                        .foregroundStyle(AG.ink800)
                }

                pushCard

                VStack(alignment: .leading, spacing: 8) {
                    Text("Flag these in Ralo").font(.ag(15, .medium))
                    VStack(spacing: 0) {
                        toggleRow("People", detail: "Any camera, any time", isOn: $people, first: true)
                        toggleRow("Parcels", detail: "Delivered and picked up", isOn: $parcels)
                        toggleRow("Vehicles", detail: "Cars arriving and leaving", isOn: $vehicles)
                        toggleRow("Animals", detail: "Off: they still show in Clips", isOn: $animals)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    .background(.white, in: RoundedRectangle(cornerRadius: AG.cardRadius, style: .continuous))
                }

                VStack(spacing: 0) {
                    toggleRow("One entry per visit", detail: "Clips close together from one camera count once",
                              isOn: $groupByVisit, first: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .background(.white, in: RoundedRectangle(cornerRadius: AG.cardRadius, style: .continuous))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(LightField())
        .navigationTitle("Alerts")
        .toolbarTitleDisplayMode(.inlineLarge)
    }

    private var pushCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Push alerts come from Arlo's app", systemImage: "bell.badge")
                .font(.ag(15, .medium))
            Text("Ralo has no server, so nothing outside your phone ever holds your Arlo sign-in. Keep Arlo's app installed with notifications on, and use Ralo to look and act.")
                .font(.ag(14))
                .foregroundStyle(AG.stone300)
                .fixedSize(horizontal: false, vertical: true)
        }
        .agInkCard()
    }

    private func toggleRow(_ title: String, detail: String, isOn: Binding<Bool>, first: Bool = false) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ag(15, .medium))
                Text(detail).font(.ag(12)).foregroundStyle(AG.stone500)
            }
        }
        .tint(AG.ink950)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(AG.hairline).frame(height: 1) }
        }
    }
}
