import XCTest
@testable import SnoreCore

/// Runs every golden fixture in spec/fixtures/ against the Swift detector and
/// replay implementations. These fixtures are THE cross-platform contract
/// (spec §1.4): the Kotlin port runs the identical files.
final class FixtureRunnerTests: XCTestCase {

    // MARK: fixture location (repo checkout layout)

    static var fixturesDir: URL {
        // …/ios/Packages/SnoreCore/Tests/SnoreCoreTests/FixtureRunnerTests.swift
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }  // → repo root
        return url.appendingPathComponent("spec/fixtures")
    }

    // MARK: JSON decoding

    struct Fixture: Decodable {
        var name: String
        var params: [String: Double]?
        var frames: [[Double]]?
        var flushAtMs: [Int64]?
        var events: [[Double]]?
        var expect: Expect
    }

    struct Expect: Decodable {
        var eventsDetected: Int?
        var confirmedEpisodes: Int?
        var episodes: [ExpectedEpisode]
        var discardedEpisodes: Int
    }

    struct ExpectedEpisode: Decodable {
        var startMs: Int64
        var endMs: Int64
        var eventCount: Int
        var snoreMs: Int64
        var peakDbfs: Double
        var nfAtPeak: Double
        var bucket: String
    }

    static func params(from overrides: [String: Double]?) throws -> DetectorParams {
        var p = DetectorParams()
        for (key, v) in overrides ?? [:] {
            switch key {
            case "WINDOW_MS": p.windowMs = Int64(v)
            case "HOP_MS": p.hopMs = Int64(v)
            case "CONF_THRESHOLD": p.confThreshold = v
            case "CONF_STRONG": p.confStrong = v
            case "SPEECH_VETO_CONF": p.speechVetoConf = v
            case "NF_INIT": p.nfInit = v
            case "NF_RISE_PER_FRAME": p.nfRisePerFrame = v
            case "NF_CLAMP_LO": p.nfClampLo = v
            case "NF_CLAMP_HI": p.nfClampHi = v
            case "GATE_OFFSET_DB": p.gateOffsetDb = v
            case "GATE_CLAMP_LO": p.gateClampLo = v
            case "GATE_CLAMP_HI": p.gateClampHi = v
            case "MERGE_GAP_MS": p.mergeGapMs = Int64(v)
            case "MIN_EPISODE_EVENTS": p.minEpisodeEvents = Int(v)
            case "MIN_EPISODE_SPAN_MS": p.minEpisodeSpanMs = Int64(v)
            case "INTENSITY_LIGHT_MAX_DB": p.intensityLightMaxDb = v
            case "INTENSITY_MOD_MAX_DB": p.intensityModMaxDb = v
            default: throw XCTSkip("unknown param \(key)")
            }
        }
        return p
    }

    static func load(_ subdir: String) throws -> [Fixture] {
        let dir = fixturesDir.appendingPathComponent(subdir)
        let files = try FileManager.default.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        XCTAssertFalse(files.isEmpty, "no fixtures found in \(dir.path)")
        return try files.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: $0)) }
    }

    // MARK: detector fixtures

    func testDetectorFixtures() throws {
        for fx in try Self.load("detector") {
            let p = try Self.params(from: fx.params)
            let detector = SnoreDetector(params: p)
            var pendingFlushes = (fx.flushAtMs ?? []).sorted()
            var eventsDetected = 0, confirmed = 0, discarded = 0
            var episodes: [ClosedEpisode] = []

            func absorb(_ outputs: [DetectorOutput]) {
                for o in outputs {
                    switch o {
                    case .eventDetected: eventsDetected += 1
                    case .episodeConfirmed: confirmed += 1
                    case .episodeClosed(let e): episodes.append(e)
                    case .episodeDiscarded: discarded += 1
                    }
                }
            }

            // Normative runner semantics (spec/reference/detector.py):
            // flush before any frame at/after a pending flush point; always
            // flush once more at session end.
            for row in fx.frames ?? [] {
                let frame = ClassifierFrame(tMs: Int64(row[0]), rmsDbfs: row[1],
                                            peakDbfs: row[2], snoreConf: row[3],
                                            speechConf: row[4])
                while let next = pendingFlushes.first, frame.tMs >= next {
                    pendingFlushes.removeFirst()
                    absorb(detector.flush())
                }
                absorb(detector.process(frame))
            }
            absorb(detector.flush())

            XCTAssertEqual(eventsDetected, fx.expect.eventsDetected, "\(fx.name): eventsDetected")
            XCTAssertEqual(confirmed, fx.expect.confirmedEpisodes, "\(fx.name): confirmed")
            XCTAssertEqual(discarded, fx.expect.discardedEpisodes, "\(fx.name): discarded")
            XCTAssertEqual(episodes.count, fx.expect.episodes.count, "\(fx.name): episode count")
            for (got, want) in zip(episodes, fx.expect.episodes) {
                XCTAssertEqual(got.startMs, want.startMs, "\(fx.name): startMs")
                XCTAssertEqual(got.endMs, want.endMs, "\(fx.name): endMs")
                XCTAssertEqual(got.events.count, want.eventCount, "\(fx.name): eventCount")
                XCTAssertEqual(got.snoreMs, want.snoreMs, "\(fx.name): snoreMs")
                XCTAssertEqual(got.peak.peakDbfs, want.peakDbfs, accuracy: 0.01, "\(fx.name): peakDbfs")
                XCTAssertEqual(got.peak.nfAtStart, want.nfAtPeak, accuracy: 0.01, "\(fx.name): nfAtPeak")
                XCTAssertEqual(got.bucket.rawValue, want.bucket, "\(fx.name): bucket")
            }
        }
    }

    // MARK: replay fixtures

    func testReplayFixtures() throws {
        for fx in try Self.load("replay") {
            let p = try Self.params(from: fx.params)
            let rows = (fx.events ?? []).map {
                EventReplay.OrphanEvent(startMs: Int64($0[0]), endMs: Int64($0[1]),
                                        peakDbfs: $0[2], maxConf: $0[3], nfDbfs: $0[4])
            }
            let result = EventReplay.replay(rows, params: p)
            XCTAssertEqual(result.discardedGroups, fx.expect.discardedEpisodes, "\(fx.name): discarded")
            XCTAssertEqual(result.episodes.count, fx.expect.episodes.count, "\(fx.name): episode count")
            for (got, want) in zip(result.episodes, fx.expect.episodes) {
                XCTAssertEqual(got.startMs, want.startMs, "\(fx.name): startMs")
                XCTAssertEqual(got.endMs, want.endMs, "\(fx.name): endMs")
                XCTAssertEqual(got.events.count, want.eventCount, "\(fx.name): eventCount")
                XCTAssertEqual(got.snoreMs, want.snoreMs, "\(fx.name): snoreMs")
                XCTAssertEqual(got.peak.peakDbfs, want.peakDbfs, accuracy: 0.01, "\(fx.name): peakDbfs")
                XCTAssertEqual(got.bucket.rawValue, want.bucket, "\(fx.name): bucket")
            }
        }
    }
}
