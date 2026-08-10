import AVFoundation
import SwiftUI
import SnoreAudio
import SnoreCore
import SnoreStorage

struct HomeView: View {
    @Environment(AppDependencies.self) private var deps
    @AppStorage("sensitivity") private var sensitivityRaw = Sensitivity.medium.rawValue
    @State private var live: RecordingSessionActor.LiveSnapshot?
    @State private var reportSessionId: String?
    @State private var startError: String?

    private var isRecording: Bool { live?.isRecording ?? false }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                if isRecording {
                    recordingBody
                } else {
                    idleBody
                }
                Spacer()
                Text(medicalDisclaimer)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            .padding()
            .navigationTitle("Snore Laboratory")
            .task {
                while !Task.isCancelled {
                    live = await deps.recorder.snapshot()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            .navigationDestination(item: $reportSessionId) { sessionId in
                ReportView(sessionId: sessionId)
            }
            .alert("Couldn't start", isPresented: .constant(startError != nil),
                   actions: { Button("OK") { startError = nil } },
                   message: { Text(startError ?? "") })
        }
    }

    private var idleBody: some View {
        VStack(spacing: 16) {
            Button {
                Task { await startTapped() }
            } label: {
                Label("Start Sleep Session", systemImage: "moon.zzz.fill")
                    .font(.title2.bold())
                    .padding(.vertical, 20)
                    .padding(.horizontal, 32)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            Text("Put your phone on the nightstand, plugged in, microphone toward you. Your phone's mic indicator stays on while it listens — audio never leaves your device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var recordingBody: some View {
        VStack(spacing: 20) {
            Image(systemName: live?.inEpisode == true
                  ? "waveform.badge.exclamationmark" : "waveform")
                .font(.system(size: 56))
                .foregroundStyle(live?.inEpisode == true ? .orange : .indigo)
                .contentTransition(.symbolEffect(.replace))
            if let startedAtMs = live?.startedAtMs {
                Text(elapsedText(sinceMs: startedAtMs))
                    .font(.system(size: 44, weight: .light, design: .rounded))
                    .monospacedDigit()
            }
            Text(live?.inEpisode == true ? "Snoring detected…" : "Listening…")
                .foregroundStyle(.secondary)
            if let nf = live?.noiseFloorDbfs {
                Text(String(format: "Room level %.0f dBFS · %d events · %d episodes",
                            nf, live?.eventsSoFar ?? 0, live?.episodesSoFar ?? 0))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Button(role: .destructive) {
                Task { await stopTapped() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
        }
    }

    private func startTapped() async {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            startError = "Microphone access is required. Enable it in Settings → Privacy → Microphone."
            return
        }
        do {
            let sensitivity = Sensitivity(rawValue: sensitivityRaw) ?? .medium
            try await deps.recorder.start(sensitivity: sensitivity)
            live = await deps.recorder.snapshot()
        } catch {
            startError = error.localizedDescription
        }
    }

    private func stopTapped() async {
        do {
            let outcome = try await deps.recorder.stop()
            live = await deps.recorder.snapshot()
            if case .saved(let sessionId) = outcome {
                reportSessionId = sessionId
            }
        } catch {
            startError = error.localizedDescription
        }
    }

    private func elapsedText(sinceMs: Int64) -> String {
        let seconds = max(0, Int64(Date().timeIntervalSince1970 * 1000) - sinceMs) / 1000
        return String(format: "%d:%02d:%02d",
                      seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}
