import AVFoundation
import Charts
import SwiftUI
import SnoreCore
import SnoreStorage

/// Night report (spec §5.1): stat row, 5-min timeline, intensity breakdown,
/// clip list. Every number is recomputed from rows via the repository.
struct ReportView: View {
    @Environment(AppDependencies.self) private var deps
    let sessionId: String

    @State private var session: SessionRecord?
    @State private var episodes: [EpisodeRecord] = []
    @State private var events: [EventRecord] = []
    @State private var gaps: [GapRecord] = []
    @State private var clips: [ClipRecord] = []
    @State private var player: AVAudioPlayer?

    var body: some View {
        List {
            if let session {
                headerSection(session)
                statSection(session)
                timelineSection(session)
                intensitySection(session)
                clipsSection
                Section {
                    Text("Snore Laboratory can't tell who — or what — is snoring.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(medicalDisclaimer)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .navigationTitle("Night Report")
        .task { load() }
    }

    private func load() {
        session = try? deps.repository.fetchSession(id: sessionId)
        episodes = (try? deps.repository.episodes(sessionId: sessionId)) ?? []
        events = (try? deps.repository.events(sessionId: sessionId)) ?? []
        gaps = (try? deps.repository.gaps(sessionId: sessionId)) ?? []
        clips = (try? deps.repository.clips(sessionId: sessionId)) ?? []
        #if DEBUG
        // Spec §5.1: stored rollups must equal a recompute from rows.
        if let s = session, s.state != .recording,
           let recomputed = try? deps.repository.recomputeRollups(sessionId: sessionId) {
            assert(recomputed.snoreTimeMs == (s.snoreTimeMs ?? 0),
                   "rollup drift: stored \(s.snoreTimeMs ?? -1) vs \(recomputed.snoreTimeMs)")
        }
        #endif
    }

    private func headerSection(_ s: SessionRecord) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(s.nightOf).font(.headline)
                if let end = s.endedAtMs {
                    Text("\(timeText(s.startedAtMs, tz: s.tzId)) – \(timeText(end, tz: s.tzId)) · \(durationText(end - s.startedAtMs)) in bed")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if s.state == .recovered {
                    Label("Recording ended unexpectedly", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if s.endReason == .autoStopped {
                    Label("Ended automatically after 12 h", systemImage: "clock.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let end = s.endedAtMs, end - s.startedAtMs < 3_600_000 {
                    Label("Short session", systemImage: "hourglass")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statSection(_ s: SessionRecord) -> some View {
        Section {
            HStack {
                stat(durationText(s.snoreTimeMs ?? 0), "Snore time")
                Divider()
                stat("\(percentOfNight(s))%", "of night")
                Divider()
                stat("\(s.episodeCount ?? 0)", "Episodes")
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack {
            Text(value).font(.title3.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func timelineSection(_ s: SessionRecord) -> some View {
        if let end = s.endedAtMs {
            let bins = TimelineBinning.bins(
                sessionStartMs: s.startedAtMs, sessionEndMs: end,
                events: events.compactMap { ev in
                    guard ev.episodeId != nil else { return nil }
                    return TimelineBinning.EventInterval(
                        startMs: ev.startMs, endMs: ev.endMs,
                        bucket: eventBucket(ev))
                })
            Section("Timeline") {
                if events.isEmpty && gaps.isEmpty {
                    Text("No snoring detected 🎉").foregroundStyle(.secondary)
                } else {
                    Chart {
                        ForEach(bins, id: \.index) { bin in
                            BarMark(
                                x: .value("Time", binDate(s, bin.index)),
                                y: .value("Minutes", bin.snoreSeconds / 60),
                                width: .ratio(0.9))
                            .foregroundStyle(color(bin.bucket))
                        }
                        ForEach(gaps, id: \.id) { gap in
                            RectangleMark(
                                xStart: .value("From", date(gap.startMs)),
                                xEnd: .value("To", date(gap.endMs)),
                                yStart: .value("", 0),
                                yEnd: .value("", 5))
                            .foregroundStyle(.gray.opacity(0.25))
                        }
                    }
                    .chartYScale(domain: 0...5)
                    .chartYAxisLabel("min snoring / 5 min")
                    .frame(height: 160)
                }
            }
        }
    }

    private func intensitySection(_ s: SessionRecord) -> some View {
        Section("Intensity") {
            let light = s.lightMs ?? 0, moderate = s.moderateMs ?? 0, loud = s.loudMs ?? 0
            let total = max(1, light + moderate + loud)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Rectangle().fill(color(.light))
                        .frame(width: geo.size.width * Double(light) / Double(total))
                    Rectangle().fill(color(.moderate))
                        .frame(width: geo.size.width * Double(moderate) / Double(total))
                    Rectangle().fill(color(.loud))
                        .frame(width: geo.size.width * Double(loud) / Double(total))
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 14)
            HStack {
                legend("Light", light, .light)
                legend("Moderate", moderate, .moderate)
                legend("Loud", loud, .loud)
            }
            .font(.caption)
        }
    }

    private func legend(_ name: String, _ ms: Int64, _ b: IntensityBucket) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color(b)).frame(width: 8, height: 8)
            Text("\(name) \(durationText(ms))")
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var clipsSection: some View {
        if !clips.isEmpty {
            Section("Clips") {
                ForEach(clips, id: \.id) { clip in
                    Button {
                        play(clip)
                    } label: {
                        HStack {
                            Image(systemName: "play.circle.fill")
                            VStack(alignment: .leading) {
                                Text(timeText(clip.startMs, tz: session?.tzId ?? "UTC"))
                                if let rel = relDb(for: clip) {
                                    Text(String(format: "+%.0f dB above room", rel))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text("\(clip.durationMs / 1000) s")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Clips are kept for 90 days on this device.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: helpers

    private func eventBucket(_ ev: EventRecord) -> IntensityBucket {
        let params = DetectorParams()
        let rel = ev.peakDbfs - ev.nfDbfs
        if rel < params.intensityLightMaxDb { return .light }
        if rel < params.intensityModMaxDb { return .moderate }
        return .loud
    }

    private func relDb(for clip: ClipRecord) -> Double? {
        episodes.first { $0.id == clip.episodeId }?.peakRelDb
    }

    private func play(_ clip: ClipRecord) {
        let url = deps.clipsRoot.deletingLastPathComponent()
            .appendingPathComponent(clip.fileName)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }

    private func percentOfNight(_ s: SessionRecord) -> Int {
        guard let end = s.endedAtMs, end > s.startedAtMs else { return 0 }
        return Int((Double(s.snoreTimeMs ?? 0) / Double(end - s.startedAtMs) * 100)
            .rounded())
    }

    private func color(_ bucket: IntensityBucket?) -> Color {
        switch bucket {
        case .light: return .teal
        case .moderate: return .orange
        case .loud: return .red
        case nil: return .gray.opacity(0.3)
        }
    }

    private func date(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    private func binDate(_ s: SessionRecord, _ index: Int) -> Date {
        date(s.startedAtMs + Int64(index) * TimelineBinning.binMs)
    }

    private func timeText(_ ms: Int64, tz: String) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: tz)
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date(ms))
    }

    private func durationText(_ ms: Int64) -> String {
        let minutes = ms / 60_000
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) m" : "\(minutes) m"
    }
}
