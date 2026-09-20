import Foundation

/// Debug-only tuning log: one CSV row per classifier window (2 rows/second)
/// holding the raw level and the scores for the sounds we may act on later —
/// snoring today, gasps/snorts (choking) and grinding candidates next.
///
/// The model already computes all 521 AudioSet scores per window; production
/// keeps two of them and drops the rest. Writing the interesting ones to disk
/// turns a real night in the user's own bedroom into the data that sets the
/// thresholds, instead of guessing them. ~4 MB for an 8 h night.
///
/// Never audio: this is numbers only, so it does not touch the "full-night
/// audio is never stored" promise.
public final class ScoreLog: @unchecked Sendable {

    /// Columns after the fixed ones, all verified to exist in the bundled
    /// class map (`ScoreLogTests` fails if one does not). Snoring/Speech are
    /// what the detector uses; Gasp/Snort are the choking candidates;
    /// Chewing/Biting/Scrape/Squeak are the nearest things YAMNet has to
    /// teeth grinding — it has no grinding class, so this is how we learn
    /// what fires instead. ("Grind" is in the AudioSet ontology but not in
    /// YAMNet's 521 output classes.)
    public static let watchedClasses = [
        "Snoring", "Speech", "Gasp", "Snort", "Breathing", "Cough",
        "Throat clearing", "Wheeze", "Pant", "Sigh", "Grunt", "Groan",
        "Chewing, mastication", "Biting", "Scrape", "Squeak", "Silence",
    ]

    private let url: URL
    private let lock = NSLock()
    private var pending: [String] = []
    private var handle: FileHandle?
    /// One flush a minute: an overnight run should not wake the disk 2×/second.
    private static let flushEveryRows = 120

    public init(url: URL, columns: [String]) {
        self.url = url
        let header = (["iso_time", "sample_end", "rms_dbfs", "peak_dbfs", "gain_db"]
            + columns.map { $0.replacingOccurrences(of: ", ", with: "/") })
            .joined(separator: ",") + "\n"
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(header.utf8))
        handle = try? FileHandle(forWritingTo: url)
        try? handle?.seekToEnd()
    }

    public func append(sampleEnd: Int64, rmsDbfs: Double, peakDbfs: Double,
                       gainDb: Double, scores: [Double]) {
        var row = "\(Self.stamp.string(from: Date())),\(sampleEnd)"
        for value in [rmsDbfs, peakDbfs, gainDb] {
            row += String(format: ",%.1f", value)
        }
        for value in scores {
            row += String(format: ",%.4f", value)
        }
        lock.lock()
        pending.append(row)
        let due = pending.count >= Self.flushEveryRows
        let batch = due ? pending : []
        if due { pending.removeAll(keepingCapacity: true) }
        lock.unlock()
        write(batch)
    }

    /// Flush and close. Safe to call more than once.
    public func finish() {
        lock.lock()
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
        write(batch)
        lock.lock()
        try? handle?.close()
        handle = nil
        lock.unlock()
    }

    private func write(_ rows: [String]) {
        guard !rows.isEmpty else { return }
        let data = Data((rows.joined(separator: "\n") + "\n").utf8)
        lock.lock()
        // A failed write (disk full) must never take the night down; the log
        // is a tuning aid, not a product feature.
        try? handle?.write(contentsOf: data)
        lock.unlock()
    }

    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
