import SwiftUI
import SnoreCore
import SnoreAudio
import SnoreStorage

@main
struct DreamCatcherApp: App {
    @State private var deps = AppDependencies.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(deps)
        }
    }
}

/// Composition root: one database, one repository, one recording actor.
@Observable
final class AppDependencies {
    let repository: SessionRepository
    let recorder: RecordingSessionActor
    /// Created at launch so it is the notification delegate before a tap on
    /// a bedtime reminder is delivered.
    let bedtimeReminder = BedtimeReminder()
    let clipsRoot: URL
    let spikeLogDir: URL
    /// Where debug score logs land; also what Settings offers to share.
    let scoreLogDir: URL

    init(repository: SessionRepository, clipsRoot: URL, spikeLogDir: URL) {
        self.repository = repository
        self.clipsRoot = clipsRoot
        self.spikeLogDir = spikeLogDir
        self.scoreLogDir = spikeLogDir.appendingPathComponent("scores")
        let scoreLogDir = self.scoreLogDir
        self.recorder = RecordingSessionActor(
            repository: repository, clipsRoot: clipsRoot,
            makeClassifier: {
                #if DEBUG
                // Read at session start, so flipping the switch takes effect
                // on the next night rather than mid-session.
                guard UserDefaults.standard.bool(forKey: scoreLoggingKey) else {
                    return YAMNetClassifier()
                }
                let name = ISO8601DateFormatter.scoreLogName.string(from: Date())
                return YAMNetClassifier(scoreLog: ScoreLog(
                    url: scoreLogDir.appendingPathComponent("\(name).csv"),
                    columns: ScoreLog.watchedClasses))
                #else
                return YAMNetClassifier()
                #endif
            })
    }

    static func live() -> AppDependencies {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let db = try! AppDatabase.open(directory: appSupport)
        let repository = SessionRepository(db)
        // Crash recovery on every launch (spec §3.1).
        _ = try? repository.recoverOrphanSessions()

        let clipsRoot = appSupport.appendingPathComponent("clips")
        try? FileManager.default.createDirectory(
            at: clipsRoot, withIntermediateDirectories: true)
        // Audio never leaves the device: clips are excluded from backups
        // (spec §6); the metrics DB rides along in normal backups.
        var clipsURL = clipsRoot
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? clipsURL.setResourceValues(values)

        // Overnight writes happen while the device is locked, so nothing may
        // carry NSFileProtectionComplete (design-ios §4).
        applyUnlockedOnceProtection(under: appSupport)

        // Retention + orphan GC (spec §4): expire 90-day-old clips, then
        // delete any file the DB no longer references (crashed nights,
        // discarded sessions, rows removed by "delete all data").
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        for expired in (try? repository.expireClips(nowMs: nowMs)) ?? [] {
            try? FileManager.default.removeItem(
                at: appSupport.appendingPathComponent(expired))
        }
        if let referenced = try? repository.allClipFileNames(),
           let files = FileManager.default.enumerator(
               at: clipsRoot, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in files
            where url.pathExtension == "m4a" {
                let name = "clips/\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
                if !referenced.contains(name) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask)[0]
        return AppDependencies(repository: repository, clipsRoot: clipsRoot,
                               spikeLogDir: docs)
    }

    /// Downgrade file protection to `.completeUntilFirstUserAuthentication`
    /// for the DB, its WAL/SHM siblings, and the clips tree. iOS grants this
    /// class by default, but it is the difference between a report and a
    /// corrupt night if that ever changes — so it is asserted, not assumed.
    private static func applyUnlockedOnceProtection(under root: URL) {
        let attrs: [FileAttributeKey: Any] =
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try? FileManager.default.setAttributes(attrs, ofItemAtPath: root.path)
        guard let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in files {
            try? FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
        }
    }
}

struct RootView: View {
    enum Tab { case sleep, history, settings }

    @Environment(AppDependencies.self) private var deps
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var tab = Tab.sleep

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("Sleep", systemImage: "moon.zzz.fill") }
                .tag(Tab.sleep)
            HistoryView()
                .tabItem { Label("History", systemImage: "calendar") }
                .tag(Tab.history)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        // A bedtime-reminder tap lands on the Sleep tab, where HomeView
        // starts the session.
        .onChange(of: deps.bedtimeReminder.startRequested, initial: true) { _, requested in
            if requested { tab = .sleep }
        }
        // Keep the next two weeks of reminders queued.
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            Task {
                let recording = await deps.recorder.snapshot().isRecording
                await deps.bedtimeReminder.reschedule(isRecording: recording)
            }
        }
        .fullScreenCover(isPresented: .constant(!hasOnboarded)) {
            OnboardingView { hasOnboarded = true }
        }
    }
}

let medicalDisclaimer = """
Dream Catcher is not a medical device. It does not diagnose, treat, or \
monitor any medical condition, including sleep apnea. If you are concerned \
about your sleep or breathing, talk to a physician.
"""

#if DEBUG
/// Settings switch: log every window's classifier scores for threshold
/// tuning (spec §0.1 constants are set from real nights, not guesses).
let scoreLoggingKey = "debugScoreLogging"

extension ISO8601DateFormatter {
    static let scoreLogName: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        formatter.timeZone = .current
        return formatter
    }()
}
#endif
