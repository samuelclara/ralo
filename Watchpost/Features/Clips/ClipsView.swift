import SwiftUI

struct ClipsView: View {
    let store: CameraStore

    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var clips: [ArloClip] = []
    @State private var filter: ClipCategory?
    @State private var isLoading = false
    @State private var playing: Visit?
    @State private var showDatePicker = false
    @AppStorage(PreferenceKey.groupByVisit) private var groupByVisit = true

    private var visits: [Visit] { Visit.group(clips, byVisit: groupByVisit) }
    private var shown: [Visit] { visits.filter { filter == nil || $0.category == filter } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                dayChips
                summary
                filterChips
                if isLoading && clips.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
                } else if shown.isEmpty {
                    Text(filter == nil ? "No clips on this day." : "No \(filter!.plural.lowercased()) on this day.")
                        .font(.ag(15))
                        .foregroundStyle(AG.stone500)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                } else {
                    groups
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: 960)
            .frame(maxWidth: .infinity)
        }
        .background(LightField())
        .navigationTitle("Clips")
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showDatePicker = true
                } label: {
                    Image(systemName: "calendar")
                }
                .accessibilityLabel("Pick a date")
            }
        }
        .task(id: day) { await load() }
        .refreshable { await load() }
        .onChange(of: store.todayClips) { _, fresh in
            if Calendar.current.isDateInToday(day) { clips = fresh }
        }
        .sheet(item: $playing) { visit in
            ClipPlayerView(visit: visit, cameraName: store.camera(id: visit.cameraId)?.name ?? "Camera")
        }
        .sheet(isPresented: $showDatePicker) {
            NavigationStack {
                DatePicker("Day", selection: $day, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(AG.ember)
                    .padding()
                    .navigationTitle("Choose a day")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showDatePicker = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func load() async {
        isLoading = true
        clips = await store.clips(on: day)
        isLoading = false
    }

    // MARK: Header

    private var dayChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { offset in
                    let date = Calendar.current.date(byAdding: .day, value: -offset, to: Calendar.current.startOfDay(for: Date()))!
                    Chip(title: label(for: date, offset: offset),
                         isSelected: Calendar.current.isDate(date, inSameDayAs: day)) {
                        day = date
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func label(for date: Date, offset: Int) -> String {
        switch offset {
        case 0: return "Today"
        case 1: return "Yesterday"
        default: return date.formatted(.dateTime.weekday(.abbreviated).day())
        }
    }

    private var summary: some View {
        let counts = Dictionary(grouping: visits, by: \.category).mapValues(\.count)
        let order: [ClipCategory] = [.person, .vehicle, .package, .animal, .other]
        let present = order.filter { (counts[$0] ?? 0) > 0 }
        let cameras = Set(visits.map(\.cameraId)).count

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(groupByVisit ? "Visits" : "Clips").font(.ag(15, .medium))
                Spacer()
                Text(groupByVisit ? "grouped by visit" : "every clip")
                    .font(.ag(13))
                    .foregroundStyle(AG.stone300)
            }
            Figure(
                value: "\(shown.count)",
                unit: filter == nil ? "across \(cameras) camera\(cameras == 1 ? "" : "s")" : "with \(filter!.plural.lowercased())",
                size: 88,
                unitColor: AG.stone300
            )
            if !present.isEmpty {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        ForEach(present) { category in
                            Rectangle()
                                .fill(AG.color(for: category))
                                .frame(width: proxy.size.width * CGFloat(counts[category] ?? 0) / CGFloat(max(visits.count, 1)))
                        }
                    }
                }
                .frame(height: 8)
                .background(.white.opacity(0.2))
                .clipShape(Capsule())

                HStack(spacing: 14) {
                    ForEach(present) { category in
                        HStack(spacing: 6) {
                            Circle().fill(AG.color(for: category)).frame(width: 10, height: 10)
                            Text("\(category.plural) \(counts[category] ?? 0)")
                        }
                    }
                }
                .font(.ag(12))
                .foregroundStyle(AG.stone300)
            }
        }
        .agInkCard()
        .accessibilityElement(children: .combine)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Chip(title: "All", count: visits.count, isSelected: filter == nil) { filter = nil }
                ForEach([ClipCategory.person, .vehicle, .package, .animal]) { category in
                    Chip(title: category.plural,
                         count: visits.filter { $0.category == category }.count,
                         isSelected: filter == category) {
                        filter = filter == category ? nil : category
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: List

    private struct VisitGroup: Identifiable {
        let part: DayPart
        let visits: [Visit]
        var id: String { part.rawValue }
    }

    private var groups: some View {
        let parts: [VisitGroup] = DayPart.allCases.compactMap { part in
            let items = shown.filter { DayPart(date: $0.start) == part }
            return items.isEmpty ? nil : VisitGroup(part: part, visits: items)
        }
        return VStack(alignment: .leading, spacing: 18) {
            ForEach(parts) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.part.rawValue).font(.ag(15, .medium))
                    VStack(spacing: 0) {
                        ForEach(Array(group.visits.enumerated()), id: \.element.id) { index, visit in
                            Button { playing = visit } label: {
                                VisitRow(visit: visit, cameraName: store.camera(id: visit.cameraId)?.name ?? "Camera")
                            }
                            .buttonStyle(.plain)
                            .overlay(alignment: .top) {
                                if index > 0 { Rectangle().fill(AG.hairline).frame(height: 1) }
                            }
                            .accessibilityHint("Plays the clip")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    .background(.white, in: RoundedRectangle(cornerRadius: AG.cardRadius, style: .continuous))
                }
            }
        }
    }
}
