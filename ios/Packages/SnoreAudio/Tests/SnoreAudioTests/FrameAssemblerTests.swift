import XCTest
@testable import SnoreAudio
import SnoreCore

/// The score-attachment rule (spec §0.1): a frame carries the classifier
/// score for ITS window, not the previous hop's, and never one from before a
/// capture gap.
final class FrameAssemblerTests: XCTestCase {

    private func samples(_ count: Int, level: Float = 0.1) -> [Float] {
        [Float](repeating: level, count: count)
    }

    private func scores(end: Int64, snore: Double) -> ClassifierScores {
        ClassifierScores(endSampleIndex: end, snoreConf: snore, speechConf: 0)
    }

    func testFrameWaitsForTheScoreOfItsOwnWindow() {
        let assembler = FrameAssembler(anchorMs: 1_000_000, anchorSampleIndex: 0)
        // First hop boundary with a full window: the frame is held, not emitted.
        XCTAssertTrue(assembler.push(samples(16_000)).isEmpty)
        // Its score lands a moment later and releases it.
        let frames = assembler.attach(scores: scores(end: 16_000, snore: 0.9))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].tMs, 1_000_000)
        XCTAssertEqual(frames[0].snoreConf, 0.9)
        // Nothing left to release.
        XCTAssertTrue(assembler.attach(scores: scores(end: 16_000, snore: 0.1)).isEmpty)
    }

    func testEachFrameGetsItsOwnScoreAcrossConsecutiveHops() {
        let assembler = FrameAssembler(anchorMs: 0, anchorSampleIndex: 0)
        var emitted: [ClassifierFrame] = []
        emitted += assembler.push(samples(16_000))
        emitted += assembler.attach(scores: scores(end: 16_000, snore: 0.2))
        emitted += assembler.push(samples(8_000))
        emitted += assembler.attach(scores: scores(end: 24_000, snore: 0.8))
        emitted += assembler.push(samples(8_000))
        emitted += assembler.attach(scores: scores(end: 32_000, snore: 0.4))
        XCTAssertEqual(emitted.map(\.tMs), [0, 500, 1_000])
        XCTAssertEqual(emitted.map(\.snoreConf), [0.2, 0.8, 0.4])
    }

    func testMissingScoreFallsBackAtTheNextHopAndKeepsOrder() {
        let assembler = FrameAssembler(anchorMs: 0, anchorSampleIndex: 0)
        XCTAssertTrue(assembler.push(samples(16_000)).isEmpty)
        _ = assembler.attach(scores: scores(end: 16_000, snore: 0.7))   // releases frame 0
        XCTAssertTrue(assembler.push(samples(8_000)).isEmpty)           // frame 500 held
        // No score for 24 000 ever arrives; the next boundary forces it out
        // with the newest score still fresh enough (the one ending at 16 000).
        let forced = assembler.push(samples(8_000))
        XCTAssertEqual(forced.map(\.tMs), [500])
        XCTAssertEqual(forced[0].snoreConf, 0.7)
    }

    func testStaleScoreReadsAsZero() {
        let assembler = FrameAssembler(anchorMs: 0, anchorSampleIndex: 0)
        _ = assembler.push(samples(16_000))
        _ = assembler.attach(scores: scores(end: 16_000, snore: 0.9))
        // 4 s of audio with a dead classifier: frames keep coming, all forced.
        let forced = assembler.push(samples(64_000))
        XCTAssertEqual(forced.count, 7)   // the 8th is still held
        // Frames ending more than 3 s after the last score carry zero.
        XCTAssertEqual(forced.last?.snoreConf, 0)
        XCTAssertTrue(assembler.classifierIsStale)
    }

    func testDrainReleasesTheHeldFrameBeforeAFlush() {
        let assembler = FrameAssembler(anchorMs: 0, anchorSampleIndex: 0)
        _ = assembler.push(samples(16_000))
        let drained = assembler.drain()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0].snoreConf, 0)
        XCTAssertTrue(assembler.drain().isEmpty)
    }

    func testScoresFromBeforeTheAnchorAreIgnored() {
        // Capture resumed at session sample 123 456 after an interruption.
        let assembler = FrameAssembler(anchorMs: 0, anchorSampleIndex: 123_456)
        // A result for a pre-gap window arrives late.
        XCTAssertTrue(assembler.attach(scores: scores(end: 123_456, snore: 0.95)).isEmpty)
        _ = assembler.push(samples(16_000))
        let drained = assembler.drain()
        XCTAssertEqual(drained[0].snoreConf, 0, "pre-gap snoring must not colour the first post-gap frame")
    }

    func testOlderScoreArrivingLateDoesNotReplaceANewerOne() {
        let assembler = FrameAssembler(anchorMs: 0, anchorSampleIndex: 0)
        _ = assembler.push(samples(16_000))
        _ = assembler.attach(scores: scores(end: 16_000, snore: 0.1))
        _ = assembler.push(samples(8_000))
        _ = assembler.attach(scores: scores(end: 24_000, snore: 0.8))
        _ = assembler.push(samples(8_000))                 // frame ending 32 000 held
        XCTAssertTrue(assembler.attach(scores: scores(end: 16_000, snore: 0.99)).isEmpty)
        let drained = assembler.drain()
        XCTAssertEqual(drained[0].snoreConf, 0.8)
    }

    func testNearerOfTwoStraddlingScoresWinsOnMisalignedGrids() {
        // Classifier rebuilt mid-segment: its grid is offset from the frames'.
        let assembler = FrameAssembler(anchorMs: 0, anchorSampleIndex: 0)
        _ = assembler.push(samples(16_000))
        _ = assembler.attach(scores: scores(end: 16_000, snore: 0.5))
        _ = assembler.push(samples(8_000))                 // frame ends at 24 000
        _ = assembler.attach(scores: scores(end: 23_000, snore: 0.9))   // 1 000 before
        let released = assembler.attach(scores: scores(end: 31_000, snore: 0.2)) // 7 000 after
        XCTAssertEqual(released.count, 1)
        XCTAssertEqual(released[0].snoreConf, 0.9)
    }
}
