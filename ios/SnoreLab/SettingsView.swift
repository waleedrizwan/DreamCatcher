import SwiftUI
import UIKit
import SnoreCore
import SnoreAudio

struct SettingsView: View {
    @Environment(AppDependencies.self) private var deps
    @AppStorage("sensitivity") private var sensitivityRaw = Sensitivity.medium.rawValue
    @State private var confirmingDelete = false
    #if DEBUG
    @AppStorage(scoreLoggingKey) private var scoreLogging = false
    @State private var scoreLogs: [URL] = []
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section("Detection") {
                    Picker("Sensitivity", selection: $sensitivityRaw) {
                        Text("Low").tag(Sensitivity.low.rawValue)
                        Text("Medium").tag(Sensitivity.medium.rawValue)
                        Text("High").tag(Sensitivity.high.rawValue)
                    }
                    Text("Higher sensitivity detects quieter snoring but may pick up more room noise. Takes effect next session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Privacy") {
                    Text("Everything stays on this phone: no accounts, no cloud, zero network calls. Only short clips of detected snoring are saved — never full-night audio — and audio is excluded from phone backups.")
                        .font(.footnote)
                    Button("Delete all data", role: .destructive) {
                        confirmingDelete = true
                    }
                }
                #if DEBUG
                // Internal test surface: never ships in a release build.
                Section("Developer") {
                    NavigationLink("Spike 0 — locked-screen classifier soak test") {
                        SpikeView()
                    }
                    Toggle("Log classifier scores", isOn: $scoreLogging)
                    Text("Writes one row per half-second of the night — level plus the model's scores for snoring, gasp, snort, cough, breathing and the grinding candidates. Numbers only, no audio. About 4 MB a night. Takes effect on the next session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !scoreLogs.isEmpty {
                        ForEach(scoreLogs, id: \.self) { url in
                            ShareLink(item: url) {
                                Label(url.lastPathComponent, systemImage: "square.and.arrow.up")
                                    .font(.caption)
                            }
                        }
                        Button("Delete score logs", role: .destructive) {
                            for url in scoreLogs { try? FileManager.default.removeItem(at: url) }
                            scoreLogs = []
                        }
                        .font(.caption)
                    }
                }
                #endif
                Section("About") {
                    Text(medicalDisclaimer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            #if DEBUG
            .task {
                scoreLogs = ((try? FileManager.default.contentsOfDirectory(
                    at: deps.scoreLogDir, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "csv" }
                    .sorted { $0.lastPathComponent > $1.lastPathComponent }
            }
            #endif
            .confirmationDialog("Delete all nights, episodes, and clips? This cannot be undone.",
                                isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) { deleteAll() }
            }
        }
    }

    private func deleteAll() {
        try? deps.repository.db.writer.write { dbc in
            try dbc.execute(sql: "DELETE FROM session")
        }
        try? FileManager.default.removeItem(at: deps.clipsRoot)
        try? FileManager.default.createDirectory(
            at: deps.clipsRoot, withIntermediateDirectories: true)
    }
}

#if DEBUG
/// Spike 0 UI (plan M0): run on a physical device, lock the screen for an
/// hour, come back and read the verdict lines. Debug-only — App Review must
/// never see an internal soak-test screen.
struct SpikeView: View {
    enum Classifier: String, CaseIterable, Identifiable {
        case yamnet = "YAMNet (Core ML, CPU only)"
        case builtIn = "Apple built-in (SoundAnalysis)"
        var id: String { rawValue }
    }

    @Environment(AppDependencies.self) private var deps
    @State private var runner: SpikeRunner?
    @State private var running = false
    @State private var choice: Classifier = .yamnet
    @State private var lines: [SpikeRunner.LogLine] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Answers the go/no-go question: does the chosen classifier keep producing results while the screen is locked? Start, lock the phone in any room for 60+ minutes (a snoring video nearby makes the snore score move), then read the newest line: OK = results flowing, STALLED = inference dead in the background.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Classifier", selection: $choice) {
                ForEach(Classifier.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .disabled(running)
            Button(running ? "Stop spike" : "Start spike") {
                Task { await toggle() }
            }
            .buttonStyle(.borderedProminent)
            .tint(running ? .red : .indigo)
            List(lines) { line in
                Text(line.text)
                    .font(.system(size: 11, design: .monospaced))
            }
            .listStyle(.plain)
        }
        .padding()
        .navigationTitle("Spike 0")
        .task {
            while !Task.isCancelled {
                if let runner {
                    lines = await runner.recentLines().reversed()
                    running = await runner.isRunning
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func toggle() async {
        if let runner, await runner.isRunning {
            await runner.stop()
            running = false
            return
        }
        let make: @Sendable () -> SnoreClassifying
        switch choice {
        case .yamnet: make = { YAMNetClassifier() }
        case .builtIn: make = { SoundAnalysisClassifier() }
        }
        let runner = SpikeRunner(logDirectory: deps.spikeLogDir,
                                 classifierName: choice.rawValue,
                                 restartOnError: choice == .yamnet,
                                 makeClassifier: make,
                                 probe: { await Self.environmentLine() })
        do {
            try await runner.start()
            self.runner = runner
            running = await runner.isRunning
        } catch {
            // Keep the message on screen: with no runner the poll loop leaves
            // `lines` alone. The same line is already in spike0.log.
            self.runner = nil
            running = false
            lines = [.init(id: 0, text: "Start failed: \(error)")]
        }
    }

    /// App state and battery for the log: the overnight cost of CPU
    /// inference is measured here, not guessed.
    @MainActor
    private static func environmentLine() -> String {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let state: String
        switch UIApplication.shared.applicationState {
        case .active: state = "active"
        case .inactive: state = "inactive"
        case .background: state = "background"
        @unknown default: state = "unknown"
        }
        let level = device.batteryLevel < 0 ? "?" : "\(Int(device.batteryLevel * 100))%"
        let charging = device.batteryState == .charging || device.batteryState == .full
        return "app=\(state) bat=\(level)\(charging ? "+" : "")"
    }
}
#endif
