import SwiftUI
import SnoreCore
import SnoreAudio

struct SettingsView: View {
    @Environment(AppDependencies.self) private var deps
    @AppStorage("sensitivity") private var sensitivityRaw = Sensitivity.medium.rawValue
    @State private var confirmingDelete = false

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
                Section("Developer") {
                    NavigationLink("Spike 0 — background classifier soak test") {
                        SpikeView()
                    }
                }
                Section("About") {
                    Text(medicalDisclaimer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
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

/// Spike 0 UI (plan M0): run on a physical device, lock the screen for an
/// hour, come back and read the verdict lines.
struct SpikeView: View {
    @Environment(AppDependencies.self) private var deps
    @State private var runner: SpikeRunner?
    @State private var running = false
    @State private var lines: [SpikeRunner.LogLine] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Answers the go/no-go question: does the built-in SoundAnalysis classifier keep producing results while the screen is locked? Start, lock the phone next to a snoring video for 60+ minutes, then check: OK = results flowing, STALLED = classifier dead in background (→ Core ML path).")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        if runner == nil {
            runner = SpikeRunner(logDirectory: deps.spikeLogDir)
        }
        guard let runner else { return }
        if await runner.isRunning {
            await runner.stop()
        } else {
            try? await runner.start()
        }
        running = await runner.isRunning
    }
}
