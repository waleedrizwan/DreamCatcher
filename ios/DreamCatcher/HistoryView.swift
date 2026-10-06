import Charts
import SwiftUI
import SnoreStorage

/// History (spec §5.2): calendar and list views over recorded nights, plus
/// week/month trends. Missing nights are gaps — never rendered as zero, never
/// counted in an average.
struct HistoryView: View {
    @Environment(AppDependencies.self) private var deps
    @State private var sessions: [SessionRecord] = []
    @State private var trend: [SessionRepository.NightPoint] = []
    @State private var mode = Mode.calendar
    @State private var window = TrendWindow.week
    @State private var monthAnchor = Date()
    @State private var selectedSessionId: String?

    enum Mode: String, CaseIterable { case calendar = "Calendar", list = "List" }
    enum TrendWindow: String, CaseIterable {
        case week = "Week", month = "Month"
        var nights: Int { self == .week ? 7 : 30 }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No nights yet",
                        systemImage: "moon.zzz",
                        description: Text("Your first night report will appear here."))
                } else {
                    List {
                        Section {
                            Picker("View", selection: $mode) {
                                ForEach(Mode.allCases, id: \.self) {
                                    Text($0.rawValue).tag($0)
                                }
                            }
                            .pickerStyle(.segmented)
                            .listRowSeparator(.hidden)
                        }
                        if mode == .calendar {
                            calendarSection
                        } else {
                            listSection
                        }
                        trendSection
                    }
                    .navigationDestination(for: String.self) { sessionId in
                        ReportView(sessionId: sessionId)
                    }
                    .navigationDestination(item: $selectedSessionId) { sessionId in
                        ReportView(sessionId: sessionId)
                    }
                }
            }
            .navigationTitle("History")
            .task { reload() }
            .refreshable { reload() }
        }
    }

    private func reload() {
        sessions = (try? deps.repository.recentSessions()) ?? []
        trend = (try? deps.repository.nightTrend(limit: 30)) ?? []
    }

    // MARK: calendar

    private var byNight: [String: SessionRecord] {
        Dictionary(sessions.map { ($0.nightOf, $0) }, uniquingKeysWith: { a, _ in a })
    }

    @ViewBuilder
    private var calendarSection: some View {
        Section {
            HStack {
                Button {
                    monthAnchor = shiftMonth(monthAnchor, by: -1)
                } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
                Spacer()
                Text(monthTitle(monthAnchor)).font(.headline)
                Spacer()
                Button {
                    monthAnchor = shiftMonth(monthAnchor, by: 1)
                } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
                .disabled(isCurrentMonth(monthAnchor))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4),
                                     count: 7), spacing: 6) {
                // Indexed: weekday initials repeat (S M T W T F S), so
                // identifying by value would collapse the duplicates.
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, day in
                    Text(day)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(monthCells(monthAnchor).enumerated()),
                        id: \.offset) { _, cell in
                    dayCell(cell)
                }
            }
            .padding(.vertical, 4)
            HStack(spacing: 12) {
                legendDot(.green, "< 5 m")
                legendDot(.orange, "5–30 m")
                legendDot(.red, "30 m+")
                legendDot(Color.secondary.opacity(0.15), "No session")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func dayCell(_ cell: String) -> some View {
        if cell.isEmpty {
            Color.clear.frame(height: 38)
        } else if let session = byNight[cell] {
            // A plain Button, not a NavigationLink: inside a List, a link
            // paints a disclosure chevron into every grid cell.
            Button {
                selectedSessionId = session.id
            } label: {
                dayBadge(day: dayNumber(cell),
                         fill: severityColor(snoreMs: session.snoreTimeMs ?? 0)
                            .opacity(0.85),
                         text: .white)
            }
            .buttonStyle(.plain)
        } else {
            dayBadge(day: dayNumber(cell),
                     fill: Color.secondary.opacity(0.12), text: .secondary)
        }
    }

    private func dayBadge(day: String, fill: Color, text: Color) -> some View {
        Text(day)
            .font(.caption.weight(.medium))
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(fill, in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(text)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color)
                .frame(width: 8, height: 8)
            Text(label)
        }
    }

    // MARK: list

    private var listSection: some View {
        Section {
            ForEach(sessions, id: \.id) { session in
                NavigationLink(value: session.id) { row(session) }
            }
        }
    }

    // MARK: trends

    @ViewBuilder
    private var trendSection: some View {
        let points = Array(trend.prefix(window.nights)).reversed()
        Section("Trends") {
            Picker("Window", selection: $window) {
                ForEach(TrendWindow.allCases, id: \.self) {
                    Text($0.rawValue).tag($0)
                }
            }
            .pickerStyle(.segmented)

            Chart(Array(points), id: \.nightOf) { point in
                BarMark(
                    x: .value("Night", shortLabel(point.nightOf)),
                    y: .value("Snore minutes", point.snoreTimeMs / 60_000))
                .foregroundStyle(severityColor(snoreMs: point.snoreTimeMs))
            }
            .chartYAxisLabel("min snoring")
            .frame(height: 150)

            // Averages cover recorded nights only (spec §5.2) — the "N of M"
            // line is what keeps a sparse month from reading as a good one.
            let recorded = Array(points)
            let avgMs = recorded.isEmpty ? 0
                : recorded.reduce(0) { $0 + $1.snoreTimeMs } / Int64(recorded.count)
            let avgEpisodes = recorded.isEmpty ? 0
                : recorded.reduce(0) { $0 + $1.episodeCount } / recorded.count
            VStack(alignment: .leading, spacing: 4) {
                Text("Average \(durationText(avgMs)) of snoring · \(avgEpisodes) episodes per recorded night")
                    .font(.footnote)
                Text("\(recorded.count) of the last \(window.nights) nights recorded. Nights you didn't record are left out of the average.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ s: SessionRecord) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(s.nightOf).font(.headline)
                if let end = s.endedAtMs {
                    Text("\(durationText(end - s.startedAtMs)) in bed · \(s.episodeCount ?? 0) episodes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(durationText(s.snoreTimeMs ?? 0))
                .font(.subheadline.bold())
                .foregroundStyle(severityColor(snoreMs: s.snoreTimeMs ?? 0))
        }
    }

    private func severityColor(snoreMs: Int64) -> Color {
        switch snoreMs {
        case 0..<300_000: return .green           // < 5 min
        case 300_000..<1_800_000: return .orange  // 5–30 min
        default: return .red
        }
    }

    private func durationText(_ ms: Int64) -> String {
        let minutes = ms / 60_000
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) m" : "\(minutes) m"
    }

    // MARK: calendar math (night_of strings are local "yyyy-MM-dd")

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = Calendar.current.firstWeekday
        return c
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Day strings for the month grid, with leading blanks for alignment.
    private func monthCells(_ anchor: Date) -> [String] {
        let start = calendar.date(from: calendar.dateComponents(
            [.year, .month], from: anchor))!
        guard let range = calendar.range(of: .day, in: .month, for: start)
        else { return [] }
        let leading = (calendar.component(.weekday, from: start)
                       - calendar.firstWeekday + 7) % 7
        let comps = calendar.dateComponents([.year, .month], from: start)
        return Array(repeating: "", count: leading) + range.map {
            String(format: "%04d-%02d-%02d", comps.year!, comps.month!, $0)
        }
    }

    private func dayNumber(_ nightOf: String) -> String {
        let parts = nightOf.split(separator: "-")
        guard let last = parts.last else { return nightOf }
        return String(Int(last) ?? 0)
    }

    private func shortLabel(_ nightOf: String) -> String {
        let parts = nightOf.split(separator: "-")
        guard parts.count == 3 else { return nightOf }
        return "\(parts[1])/\(parts[2])"
    }

    private func shiftMonth(_ date: Date, by months: Int) -> Date {
        calendar.date(byAdding: .month, value: months, to: date) ?? date
    }

    private func isCurrentMonth(_ date: Date) -> Bool {
        calendar.isDate(date, equalTo: Date(), toGranularity: .month)
    }

    private func monthTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: date)
    }
}
