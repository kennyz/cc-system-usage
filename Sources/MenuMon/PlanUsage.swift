import Foundation

struct PlanUsageSample {
    let date: Date
    let org: String
    let fiveHourPercent: Int?   // "fh" — current 5-hour rate-limit window, 0...100
    let weeklyPercent: Int?     // "sd" — longer rolling window (shown as "Weekly" in Claude's own UI), 0...100
}

/// Reads the Claude desktop app's own usage cache. This is the same number shown
/// in the app's "Current session" usage bar — real data from Anthropic's servers,
/// not a local estimate. There is no other way to get a true rate-limit percentage
/// from disk; the JSONL transcripts under ~/.claude/projects only carry token
/// counts, not quota state.
enum PlanUsageReader {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    }

    /// A sample older than this is treated as unavailable rather than shown stale —
    /// a 5-hour window will have reset at least once by then, and the field format
    /// isn't officially documented enough to trust extrapolating past that.
    private static let maxAge: TimeInterval = 6 * 60 * 60

    static func latest(now: Date = Date()) -> PlanUsageSample? {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let samples = root["samples"] as? [[String: Any]]
        else { return nil }

        // Entries can be empty placeholders ("u": {}) written before any usage was
        // recorded for that org switch; skip those and take the most recent real one.
        let usable: [(t: Double, usage: [String: Any], org: String)] = samples.compactMap { sample in
            guard let t = sample["t"] as? Double,
                  let usage = sample["u"] as? [String: Any],
                  !usage.isEmpty
            else { return nil }
            return (t, usage, sample["org"] as? String ?? "")
        }
        guard let latest = usable.max(by: { $0.t < $1.t }) else { return nil }

        let date = Date(timeIntervalSince1970: latest.t / 1000)
        guard now.timeIntervalSince(date) < maxAge else { return nil }

        return PlanUsageSample(
            date: date,
            org: latest.org,
            fiveHourPercent: latest.usage["fh"] as? Int,
            weeklyPercent: latest.usage["sd"] as? Int)
    }
}

/// Anthropic resets the 5-hour rate-limit window on fixed UTC clock boundaries —
/// 00:00, 05:00, 10:00, 15:00, 20:00 — not a rolling window from last use. Verified
/// against the real `resetsAt` epoch-seconds timestamp the desktop app's web view
/// caches in IndexedDB (`~/Library/Application Support/Claude/IndexedDB/https_claude.ai_0.indexeddb.leveldb`,
/// key `resetsAt` under `rate_limit_info` / `unifiedWindows.five_hour`): it landed
/// exactly on an hour boundary in that set, and the countdown this produces matched
/// the app's own "Resets in Xh Ym" display to the minute at two different times.
/// That store is Chromium's internal binary format and gets compacted/rotated by
/// the app, so it isn't parsed here — this fixed-grid computation is deterministic
/// and needs no file access at all.
enum FiveHourWindow {
    private static let blockSeconds: TimeInterval = 5 * 60 * 60

    static func nextReset(after date: Date = Date()) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let hour = utc.component(.hour, from: date)
        let blockStartHour = (hour / 5) * 5
        var comps = utc.dateComponents([.year, .month, .day], from: date)
        comps.hour = blockStartHour
        comps.minute = 0
        comps.second = 0
        comps.nanosecond = 0
        guard let blockStart = utc.date(from: comps) else {
            return date.addingTimeInterval(blockSeconds)
        }
        var next = blockStart.addingTimeInterval(blockSeconds)
        while next <= date { next = next.addingTimeInterval(blockSeconds) }
        return next
    }

    static func timeRemaining(after date: Date = Date()) -> TimeInterval {
        nextReset(after: date).timeIntervalSince(date)
    }
}

/// Best-effort reader for the weekly ("All models" / `sd` / `seven_day`) window's
/// reset time. Unlike FiveHourWindow, there isn't enough evidence this window
/// resets on a fixed global grid — one observed sample doesn't prove a pattern —
/// so this reads the real `resetsAt` value straight from the same IndexedDB store
/// FiveHourWindow's doc comment describes, scoped to the `seven_day` window instead
/// of `five_hour`. That store is Chromium's internal, undocumented, compactable
/// format: recent writes live in plaintext-searchable `.log` files, but once
/// compacted into `.ldb` sstables the data is Snappy-block-compressed and no longer
/// found by a plain byte scan. So this can legitimately return nil — callers should
/// treat that as "no data available" and not synthesize a countdown.
enum SevenDayWindow {
    private static var leveldbDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Claude/IndexedDB/https_claude.ai_0.indexeddb.leveldb")
    }

    /// A decoded timestamp outside this range relative to `now` is treated as a
    /// false-positive byte match rather than a real weekly boundary.
    private static let plausibleRange: (past: TimeInterval, future: TimeInterval) = (-86_400, 21 * 86_400)

    static func nextReset(now: Date = Date()) -> Date? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: leveldbDir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }

        let logFiles = entries
            .filter { $0.pathExtension == "log" }
            .sorted { lhs, rhs in modDate(lhs) > modDate(rhs) }

        for file in logFiles {
            guard let data = try? Data(contentsOf: file), data.count < 50_000_000 else { continue }
            if let date = latestSevenDayReset(in: data, now: now) { return date }
        }
        return nil
    }

    private static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? .distantPast
    }

    private static func latestSevenDayReset(in data: Data, now: Date) -> Date? {
        let anchor = Data("seven_day".utf8)
        let key = Data("resetsAt".utf8)
        var best: Date?
        var searchFrom = data.startIndex

        while let anchorRange = data.range(of: anchor, in: searchFrom..<data.endIndex) {
            let proximityEnd = min(data.endIndex, anchorRange.upperBound + 40)
            if let keyRange = data.range(of: key, in: anchorRange.upperBound..<proximityEnd) {
                let doubleStart = keyRange.upperBound + 1  // skip the 1-byte type tag
                if doubleStart + 8 <= data.endIndex {
                    let value = data[doubleStart..<doubleStart + 8].withUnsafeBytes {
                        $0.loadUnaligned(as: Double.self)
                    }
                    if value.isFinite {
                        let date = Date(timeIntervalSince1970: value)
                        let delta = date.timeIntervalSince(now)
                        if delta > plausibleRange.past, delta < plausibleRange.future,
                           best == nil || date > best! {
                            best = date
                        }
                    }
                }
            }
            searchFrom = anchorRange.upperBound
        }
        return best
    }
}
