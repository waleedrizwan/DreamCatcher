import SwiftUI
import SnoreStorage

/// History (spec §5.2): per-night list, newest first. Missing nights are
/// simply absent — never rendered as zero.
struct HistoryView: View {
    @Environment(AppDependencies.self) private var deps
    @State private var sessions: [SessionRecord] = []

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No nights yet",
                        systemImage: "moon.zzz",
                        description: Text("Your first night report will appear here."))
                } else {
                    List(sessions, id: \.id) { session in
                        NavigationLink(value: session.id) {
                            row(session)
                        }
                    }
                    .navigationDestination(for: String.self) { sessionId in
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
}
