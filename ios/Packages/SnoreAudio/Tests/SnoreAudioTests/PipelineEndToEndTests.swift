import AVFoundation
import XCTest
@testable import SnoreAudio
import SnoreCore

/// Real audio through the real chain: YAMNetClassifier → FrameAssembler →
/// SnoreDetector, fed in ~100 ms chunks exactly as `RecordingSessionActor`
/// does. Needs audio that cannot be committed (tools/yamnet/README.md: clip
/// set), so it runs only when pointed at it:
///
///   TEST_RUNNER_SNORE_E2E_DIR=/path/with/e2e_snoring.wav+e2e_control.wav \
///     xcodebuild -scheme SnoreAudio -destination '…Simulator…' test
final class PipelineEndToEndTests: XCTestCase {

    private struct Outcome {
        var events = 0
        var episodes: [ClosedEpisode] = []
        var positiveFrames = 0
        var maxSnoreConf = 0.0
    }

    private func run(_ fileName: String) throws -> Outcome {
        guard let dir = ProcessInfo.processInfo.environment["SNORE_E2E_DIR"] else {
            throw XCTSkip("SNORE_E2E_DIR not set")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: dir)
            .appendingPathComponent(fileName))
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let audio = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0],
                                              count: Int(buffer.frameLength)))

        let params = DetectorParams.forSensitivity(.medium)
        let detector = SnoreDetector(params: params)
        let assembler = FrameAssembler(anchorMs: 0, anchorSampleIndex: 0)
        let classifier = YAMNetClassifier()
        let lock = NSLock()
        var arrived: [ClassifierScores] = []
        try classifier.start { scores in
            lock.lock(); arrived.append(scores); lock.unlock()
        }
        defer { classifier.stop() }

        var outcome = Outcome()
        func feed(_ frames: [ClassifierFrame]) {
            for frame in frames {
                if frame.snoreConf >= params.confThreshold { outcome.positiveFrames += 1 }
                outcome.maxSnoreConf = max(outcome.maxSnoreConf, frame.snoreConf)
                absorb(detector.process(frame), into: &outcome)
            }
        }
        var index = 0
        while index < audio.count {
            let chunk = Array(audio[index..<min(index + 1_600, audio.count)])
            classifier.process(samples: chunk, atSampleIndex: Int64(index))
            feed(assembler.push(chunk))
            // Live, scores land a few ms after the chunk; here, right after it.
            classifier.waitUntilIdle()
            lock.lock(); let scores = arrived; arrived = []; lock.unlock()
            for score in scores { feed(assembler.attach(scores: score)) }
            index += chunk.count
        }
        feed(assembler.drain())
        absorb(detector.flush(), into: &outcome)
        XCTAssertNil(classifier.lastError)
        return outcome
    }

    private func absorb(_ outputs: [DetectorOutput], into outcome: inout Outcome) {
        for output in outputs {
            switch output {
            case .eventDetected: outcome.events += 1
            case .episodeClosed(let episode): outcome.episodes.append(episode)
            case .episodeConfirmed, .episodeDiscarded: break
            }
        }
    }

    func testSnoringBoutBecomesOneEpisode() throws {
        let outcome = try run("e2e_snoring.wav")
        print("E2E snoring: events=\(outcome.events) episodes=\(outcome.episodes.count) "
              + "positiveFrames=\(outcome.positiveFrames) maxConf=\(outcome.maxSnoreConf) "
              + "snoreMs=\(outcome.episodes.map(\.snoreMs))")
        XCTAssertEqual(outcome.episodes.count, 1, "16 snores 4 s apart are one bout")
        XCTAssertGreaterThanOrEqual(outcome.events, 6)
    }

    func testNonSnoringSoundsProduceNothing() throws {
        let outcome = try run("e2e_control.wav")
        print("E2E control: events=\(outcome.events) episodes=\(outcome.episodes.count) "
              + "positiveFrames=\(outcome.positiveFrames) maxConf=\(outcome.maxSnoreConf)")
        XCTAssertEqual(outcome.episodes.count, 0)
        XCTAssertEqual(outcome.events, 0)
    }
}
