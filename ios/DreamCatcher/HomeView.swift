import AVFoundation
import SwiftUI
import UIKit
import SnoreAudio
import SnoreCore
import SnoreStorage

struct HomeView: View {
    @Environment(AppDependencies.self) private var deps
    @AppStorage("sensitivity") private var sensitivityRaw = Sensitivity.medium.rawValue
    @State private var live: RecordingSessionActor.LiveSnapshot?
    @State private var reportSessionId: String?
    @State private var startError: String?
    @State private var preFlightIssues: [String] = []
    @State private var confirmingStart = false
    @State private var confirmingStop = false

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
            .navigationTitle("Dream Catcher")
            .task {
                while !Task.isCancelled {
                    live = await deps.recorder.snapshot()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            // Tapped the bedtime reminder: start as if the button was pressed
            // (mic permission + pre-flight warnings still apply).
            .onChange(of: deps.bedtimeReminder.startRequested, initial: true) { _, requested in
                guard requested else { return }
                deps.bedtimeReminder.startRequested = false
                Task {
                    guard !(await deps.recorder.snapshot().isRecording) else { return }
                    await startTapped()
                }
            }
            .navigationDestination(item: $reportSessionId) { sessionId in
                ReportView(sessionId: sessionId)
            }
            .alert("Couldn't start", isPresented: .constant(startError != nil),
                   actions: { Button("OK") { startError = nil } },
                   message: { Text(startError ?? "") })
            .confirmationDialog("Before you sleep",
                                isPresented: $confirmingStart,
                                titleVisibility: .visible) {
                Button("Start anyway") { Task { await reallyStart() } }
                Button("Not yet", role: .cancel) {}
            } message: {
                Text(preFlightIssues.joined(separator: "\n\n"))
            }
            // Confirm-to-stop (design-ios §6): a 3 a.m. fumble for the alarm
            // must not end the night.
            .confirmationDialog("End the sleep session?",
                                isPresented: $confirmingStop,
                                titleVisibility: .visible) {
                Button("End session", role: .destructive) {
                    Task { await stopTapped() }
                }
                Button("Keep recording", role: .cancel) {}
            }
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
            if live?.clipsDisabled == true {
                Label("Storage low — saving metrics only, no clips",
                      systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if live?.classifierStalled == true {
                Label("Snore detection stalled — recovering",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button(role: .destructive) {
                confirmingStop = true
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
        // Pre-flight (design-ios §6): warn, never block — the user may know
        // something we don't about their night.
        preFlightIssues = preFlightWarnings()
        if preFlightIssues.isEmpty {
            await reallyStart()
        } else {
            confirmingStart = true
        }
    }

    /// Disk headroom and charging state — the two things that quietly ruin a
    /// night. Battery monitoring is enabled lazily, only when it's consulted.
    private func preFlightWarnings() -> [String] {
        var issues: [String] = []
        let free = DiskSpace.freeBytes(at: deps.clipsRoot)
        if free < DiskSpace.preFlightMinBytes {
            issues.append("Only \(free / 1_048_576) MB of storage is free. A full night needs about 200 MB — snore clips may be skipped.")
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let state = UIDevice.current.batteryState
        let level = UIDevice.current.batteryLevel
        if state == .unplugged || state == .unknown {
            let pct = level >= 0 ? " (\(Int(level * 100))%)" : ""
            issues.append("Your phone isn't charging\(pct). Listening all night uses a few percent per hour — plug it in to be safe.")
        }
        return issues
    }

    private func reallyStart() async {
        do {
            let sensitivity = Sensitivity(rawValue: sensitivityRaw) ?? .medium
            try await deps.recorder.start(sensitivity: sensitivity)
            live = await deps.recorder.snapshot()
            // Tonight is covered: drop a reminder that would fire mid-session.
            await deps.bedtimeReminder.reschedule(isRecording: true)
        } catch {
            startError = error.localizedDescription
        }
    }

    private func stopTapped() async {
        do {
            let outcome = try await deps.recorder.stop()
            live = await deps.recorder.snapshot()
            switch outcome {
            case .saved(let sessionId):
                reportSessionId = sessionId
            case .discardedTooShort:
                startError = "Session under 2 minutes — not saved."
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
