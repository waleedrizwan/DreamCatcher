import XCTest
@testable import SnoreAudio

final class ScoreLogTests: XCTestCase {

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("scorelog-\(UUID().uuidString)")
            .appendingPathComponent("night.csv")
    }

    func testWritesHeaderAndRowsWithCommaSafeColumnNames() throws {
        let url = temporaryURL()
        let log = ScoreLog(url: url, columns: ["Snoring", "Chewing, mastication"])
        log.append(sampleEnd: 16_000, rmsDbfs: -42.25, peakDbfs: -30.5,
                   gainDb: 12.0, scores: [0.917_3, 0.001_2])
        log.finish()
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0],
                       "iso_time,sample_end,rms_dbfs,peak_dbfs,gain_db,Snoring,Chewing/mastication",
                       "a column name containing a comma would shift every later column")
        let fields = lines[1].split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(fields.count, 7)
        XCTAssertEqual(fields[1], "16000")
        XCTAssertEqual(fields[2], "-42.2")      // one decimal
        XCTAssertEqual(fields[5], "0.9173")     // four decimals
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testRowsSurviveWithoutAnExplicitFinish() throws {
        // A night that ends in a crash must still leave the flushed rows on
        // disk; only the last partial batch can be lost.
        let url = temporaryURL()
        let log = ScoreLog(url: url, columns: ["Snoring"])
        for i in 0..<300 {
            log.append(sampleEnd: Int64(i) * 8_000, rmsDbfs: -60, peakDbfs: -50,
                       gainDb: 0, scores: [0.5])
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let rows = text.split(separator: "\n").count - 1
        XCTAssertGreaterThanOrEqual(rows, 240, "flushes every 120 rows")
        log.finish()
        let final = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(final.split(separator: "\n").count - 1, 300)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testClassifierLogsOneRowPerWindow() throws {
        let url = temporaryURL()
        let log = ScoreLog(url: url, columns: ScoreLog.watchedClasses)
        let classifier = YAMNetClassifier(scoreLog: log)
        let lock = NSLock()
        var count = 0
        let expectation = expectation(description: "three results")
        try classifier.start { _ in
            lock.lock(); count += 1; let n = count; lock.unlock()
            if n == 3 { expectation.fulfill() }
        }
        let chunk = [Float](repeating: 0.05, count: 1_600)
        var index: Int64 = 0
        while index < 32_000 {
            classifier.process(samples: chunk, atSampleIndex: index)
            index += 1_600
        }
        wait(for: [expectation], timeout: 20)
        classifier.stop()   // flushes

        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 4, "header + one row per window")
        let header = lines[0].split(separator: ",").map(String.init)
        XCTAssertEqual(header.count, 5 + ScoreLog.watchedClasses.count,
                       "every watched class must exist in the bundled class map")
        let row = lines[1].split(separator: ",").map(String.init)
        XCTAssertEqual(row.count, header.count)
        XCTAssertEqual(row[1], "16000")
        // Constant 0.05 samples: about -26 dBFS raw, lifted toward the 0.5 target.
        XCTAssertEqual(Double(row[2])!, -26.0, accuracy: 0.5)
        XCTAssertEqual(Double(row[4])!, 20.0, accuracy: 0.5)
        let snoring = header.firstIndex(of: "Snoring")!
        XCTAssertLessThan(Double(row[snoring])!, 0.35)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
