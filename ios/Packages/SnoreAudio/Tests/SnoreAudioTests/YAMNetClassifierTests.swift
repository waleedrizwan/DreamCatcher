import XCTest
@testable import SnoreAudio
import SnoreCore

/// Exercises the glue around the bundled model: resource lookup through
/// `Bundle.module`, the class-map assertion, hop alignment on the session
/// sample grid, and the restart-on-discontinuity rule. The model's own
/// accuracy is characterized offline (tools/yamnet/validate.py).
final class YAMNetClassifierTests: XCTestCase {

    func testLabelIndicesComeFromTheBundledClassMap() throws {
        let labels = try YAMNetClassifier.labelIndices()
        XCTAssertEqual(labels.snore, 38)
        XCTAssertEqual(labels.speech, 0)
    }

    func testResultsLandOnHopBoundariesAndSilenceScoresLow() throws {
        let classifier = YAMNetClassifier()
        let lock = NSLock()
        var received: [ClassifierScores] = []
        let expectation = expectation(description: "five results")
        try classifier.start { scores in
            lock.lock()
            received.append(scores)
            let count = received.count
            lock.unlock()
            if count == 5 { expectation.fulfill() }
        }
        defer { classifier.stop() }

        // 3 s of near-silence in ~100 ms chunks, contiguous session indices.
        var index: Int64 = 0
        let chunk = [Float](repeating: 1e-5, count: 1_600)
        while index < 48_000 {
            classifier.process(samples: chunk, atSampleIndex: index)
            index += Int64(chunk.count)
        }
        wait(for: [expectation], timeout: 20)

        lock.lock(); defer { lock.unlock() }
        // First window completes at 15 600 samples; the first hop boundary
        // after that is 16 000, then every 8 000.
        XCTAssertEqual(received.map(\.endSampleIndex),
                       [16_000, 24_000, 32_000, 40_000, 48_000])
        for scores in received {
            XCTAssertLessThan(scores.snoreConf, 0.35, "silence must not read as snoring")
            XCTAssertLessThan(scores.speechConf, 0.5)
        }
        XCTAssertNil(classifier.lastError)
        XCTAssertTrue(classifier.statusLine.contains("inferences=5"), classifier.statusLine)
    }

    func testResetDropsBufferedAudioEvenWhenTheIndexIsContiguous() throws {
        let classifier = YAMNetClassifier()
        let lock = NSLock()
        var ends: [Int64] = []
        let expectation = expectation(description: "two results")
        try classifier.start { scores in
            lock.lock()
            ends.append(scores.endSampleIndex ?? -1)
            let count = ends.count
            lock.unlock()
            if count == 2 { expectation.fulfill() }
        }
        defer { classifier.stop() }

        let chunk = [Float](repeating: 0, count: 1_600)
        var index: Int64 = 0
        while index < 20_800 {            // one result at 16 000, then 4 800 more
            classifier.process(samples: chunk, atSampleIndex: index)
            index += 1_600
        }
        // Capture restarts after a gap. The recording actor continues the
        // sample clock exactly where it stopped, so only reset() marks the gap.
        classifier.reset()
        while index < 20_800 + 17_600 {
            classifier.process(samples: chunk, atSampleIndex: index)
            index += 1_600
        }
        wait(for: [expectation], timeout: 20)

        lock.lock(); defer { lock.unlock() }
        // Without the reset the second result would come at 24 000, built from
        // pre-gap audio. With it, the grid restarts at 20 800.
        XCTAssertEqual(ends, [16_000, 36_800])
    }

    func testDiscontinuityRestartsTheWindow() throws {
        let classifier = YAMNetClassifier()
        let lock = NSLock()
        var ends: [Int64] = []
        let expectation = expectation(description: "two results")
        try classifier.start { scores in
            lock.lock()
            ends.append(scores.endSampleIndex ?? -1)
            let count = ends.count
            lock.unlock()
            if count == 2 { expectation.fulfill() }
        }
        defer { classifier.stop() }

        let chunk = [Float](repeating: 0, count: 1_600)
        // 16 000 samples → one result at 16 000.
        var index: Int64 = 0
        while index < 16_000 {
            classifier.process(samples: chunk, atSampleIndex: index)
            index += 1_600
        }
        // Jump ahead to 100 000 (dropped audio): the partial window is
        // discarded and the hop grid restarts at the jump, so the next result
        // needs a full window again and lands one full frame after it.
        index = 100_000
        while index < 100_000 + 24_000 {
            classifier.process(samples: chunk, atSampleIndex: index)
            index += 1_600
        }
        wait(for: [expectation], timeout: 20)

        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(ends, [16_000, 116_000])
    }
}
