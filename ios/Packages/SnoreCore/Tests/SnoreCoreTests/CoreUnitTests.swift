import XCTest
@testable import SnoreCore

final class DetectorBehaviorTests: XCTestCase {

    /// Breath gaps (3–6 s) must not split an episode; sustained quiet must
    /// close it. The canonical behavior from the design docs, hand-written
    /// here as a readable complement to the golden fixtures.
    func testEpisodeSurvivesBreathGapsButClosesAfterQuiet() {
        let det = SnoreDetector(params: DetectorParams())
        var outputs: [DetectorOutput] = []
        var t: Int64 = 0
        func frames(_ n: Int, rms: Double, conf: Double) {
            for _ in 0..<n {
                outputs += det.process(ClassifierFrame(tMs: t, rmsDbfs: rms,
                    peakDbfs: rms + 4, snoreConf: conf, speechConf: 0))
                t += 500
            }
        }
        // 8 snore events (3 frames each) with 4 s breath gaps → one episode
        for i in 0..<8 {
            frames(3, rms: -38, conf: 0.9)
            if i < 7 { frames(8, rms: -70, conf: 0) }
        }
        frames(80, rms: -70, conf: 0)  // 40 s of quiet closes it

        let closed = outputs.compactMap {
            if case .episodeClosed(let e) = $0 { return e } else { return nil }
        }
        XCTAssertEqual(closed.count, 1, "breath gaps must not split an episode")
        XCTAssertEqual(closed[0].events.count, 8)
        let confirmed = outputs.filter {
            if case .episodeConfirmed = $0 { return true } else { return false }
        }
        XCTAssertEqual(confirmed.count, 1)
    }

    func testNoiseFloorSurvivesFlush() {
        let det = SnoreDetector(params: DetectorParams())
        for i in 0..<20 {
            _ = det.process(ClassifierFrame(tMs: Int64(i) * 500, rmsDbfs: -72,
                peakDbfs: -70, snoreConf: 0, speechConf: 0))
        }
        XCTAssertEqual(det.noiseFloorDbfs, -72, accuracy: 0.001)
        _ = det.flush()
        XCTAssertEqual(det.noiseFloorDbfs, -72, accuracy: 0.001,
                       "flush must not reset the noise floor — same room")
    }
}

final class LevelMeterTests: XCTestCase {

    func testSilenceClampsToMinus100() {
        let l = LevelMeter.measure([Float](repeating: 0, count: 16_000))
        XCTAssertEqual(l.rmsDbfs, -100)
        XCTAssertEqual(l.peakDbfs, -100)
    }

    func testFullScaleSineIsMinus3dBRms() {
        let n = 16_000
        let sine = (0..<n).map { Float(sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
        let l = LevelMeter.measure(sine)
        XCTAssertEqual(l.rmsDbfs, -3.01, accuracy: 0.05)   // 1/√2 ≈ -3.01 dB
        XCTAssertEqual(l.peakDbfs, 0, accuracy: 0.01)
    }

    func testKnownAmplitude() {
        let l = LevelMeter.measure([Float](repeating: 0.1, count: 1000))
        XCTAssertEqual(l.rmsDbfs, -20, accuracy: 0.001)
        XCTAssertEqual(l.peakDbfs, -20, accuracy: 0.001)
    }
}

final class RingBufferTests: XCTestCase {

    func testWraparoundSnapshot() {
        let ring = PCMRingBuffer(capacitySamples: 10)
        ring.write(Array(0..<25).map(Int16.init))          // 0…24; holds 15…24
        XCTAssertEqual(ring.totalWritten, 25)
        XCTAssertEqual(ring.oldestAvailableIndex, 15)
        XCTAssertEqual(ring.snapshot(from: 15, to: 25), Array(15..<25).map(Int16.init))
        XCTAssertEqual(ring.snapshot(from: 18, to: 21), [18, 19, 20])
        XCTAssertNil(ring.snapshot(from: 14, to: 20), "evicted range must be nil")
        XCTAssertNil(ring.snapshot(from: 20, to: 26), "future range must be nil")
    }

    func testLatestClampsToAvailable() {
        let ring = PCMRingBuffer(capacitySamples: 8)
        ring.write([1, 2, 3])
        XCTAssertEqual(ring.latest(100), [1, 2, 3])
        ring.write(Array(4...20).map(Int16.init))
        XCTAssertEqual(ring.latest(4), [17, 18, 19, 20])
    }

    func testClipWindowSizing() {
        // 30 s ring at 16 kHz must cover a 12 s clip with 3 s pre-roll (spec §4).
        let ring = PCMRingBuffer(seconds: 30)
        XCTAssertEqual(ring.oldestAvailableIndex, 0)
        ring.write([Int16](repeating: 0, count: 30 * 16_000))
        XCTAssertNotNil(ring.snapshot(from: ring.totalWritten - Int64(12 * 16_000),
                                      to: ring.totalWritten))
    }
}

final class TimelineBinningTests: XCTestCase {

    func testBinValuesAndSeverity() {
        let start: Int64 = 1_000_000
        let events = [
            // 60 s light event fully inside bin 0
            TimelineBinning.EventInterval(startMs: start + 10_000,
                                          endMs: start + 70_000, bucket: .light),
            // event straddling bins 1|2, loud
            TimelineBinning.EventInterval(startMs: start + 590_000,
                                          endMs: start + 610_000, bucket: .loud),
        ]
        let bins = TimelineBinning.bins(sessionStartMs: start,
                                        sessionEndMs: start + 4 * 300_000,
                                        events: events)
        XCTAssertEqual(bins.count, 4)
        XCTAssertEqual(bins[0].snoreSeconds, 60, accuracy: 0.001)
        XCTAssertEqual(bins[0].bucket, .light)
        XCTAssertEqual(bins[1].snoreSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(bins[1].bucket, .loud)
        XCTAssertEqual(bins[2].snoreSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(bins[3].snoreSeconds, 0)
        XCTAssertNil(bins[3].bucket)
    }

    func testPartialLastBin() {
        let bins = TimelineBinning.bins(sessionStartMs: 0, sessionEndMs: 450_000,
                                        events: [])
        XCTAssertEqual(bins.count, 2, "last partial bin must exist")
    }
}

final class SessionMetricsTests: XCTestCase {

    func testRollupsFromEpisodes() {
        let p = DetectorParams()
        var e1 = SnoreEvent(startMs: 0, nfAtStart: -70)
        e1.endMs = 10_000; e1.peakDbfs = -50          // relDb 20 → light
        var e2 = SnoreEvent(startMs: 20_000, nfAtStart: -70)
        e2.endMs = 26_000; e2.peakDbfs = -40          // relDb 30 → moderate
        var e3 = SnoreEvent(startMs: 40_000, nfAtStart: -68)
        e3.endMs = 44_000; e3.peakDbfs = -20          // relDb 48 → loud
        let epi = ClosedEpisode(id: 1, startMs: 0, endMs: 44_000,
                                events: [e1, e2, e3], snoreMs: 20_000,
                                peak: e3, bucket: .loud)
        let m = SessionMetrics.compute(episodes: [epi], params: p)
        XCTAssertEqual(m.snoreTimeMs, 20_000)
        XCTAssertEqual(m.lightMs, 10_000)
        XCTAssertEqual(m.moderateMs, 6_000)
        XCTAssertEqual(m.loudMs, 4_000)
        XCTAssertEqual(m.episodeCount, 1)
        XCTAssertEqual(m.noiseFloorDbfs!, -70, accuracy: 0.001)
        // 20 s of snoring in an 8 h session ≈ 0 %; in a 200 s session = 10 %
        XCTAssertEqual(m.percentOfNight(sessionStartMs: 0, sessionEndMs: 200_000), 10)
    }
}
