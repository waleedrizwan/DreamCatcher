import SwiftUI
import SnoreCore
import SnoreAudio
import SnoreStorage

@main
struct SnoreLabApp: App {
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
    let clipsRoot: URL
    let spikeLogDir: URL

    init(repository: SessionRepository, clipsRoot: URL, spikeLogDir: URL) {
        self.repository = repository
        self.clipsRoot = clipsRoot
        self.spikeLogDir = spikeLogDir
        self.recorder = RecordingSessionActor(
            repository: repository, clipsRoot: clipsRoot,
            makeClassifier: { SoundAnalysisClassifier() })
    }

    static func live() -> AppDependencies {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let db = try! AppDatabase.open(directory: appSupport)
        let repository = SessionRepository(db)
        // Crash recovery on every launch (spec §3.1).
        try? repository.recoverOrphanSessions()

        let clipsRoot = appSupport.appendingPathComponent("clips")
        try? FileManager.default.createDirectory(
            at: clipsRoot, withIntermediateDirectories: true)
        // Audio never leaves the device: clips are excluded from backups
        // (spec §6); the metrics DB rides along in normal backups.
        var clipsURL = clipsRoot
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? clipsURL.setResourceValues(values)

        let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask)[0]
        return AppDependencies(repository: repository, clipsRoot: clipsRoot,
                               spikeLogDir: docs)
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Sleep", systemImage: "moon.zzz.fill") }
            HistoryView()
                .tabItem { Label("History", systemImage: "calendar") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

let medicalDisclaimer = """
Snore Laboratory is not a medical device. It does not diagnose, treat, or \
monitor any medical condition, including sleep apnea. If you are concerned \
about your sleep or breathing, talk to a physician.
"""
