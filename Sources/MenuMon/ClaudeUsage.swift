import Foundation

// MARK: - Pricing

struct ModelPrice {
    /// USD per million tokens.
    let input: Double
    let output: Double
    /// True when we are guessing the tier rather than using a published rate.
    let estimated: Bool

    var cacheRead: Double { input * 0.10 }
    var cacheWrite5m: Double { input * 1.25 }
    var cacheWrite1h: Double { input * 2.00 }
}

enum Pricing {
    /// Published rates, USD per million tokens.
    /// Cache read is 0.1x input; cache write is 1.25x input (5m TTL) or 2x input (1h TTL).
    private static let published: [String: ModelPrice] = [
        "claude-fable-5":    ModelPrice(input: 10, output: 50, estimated: false),
        "claude-mythos-5":   ModelPrice(input: 10, output: 50, estimated: false),
        "claude-opus-4-8":   ModelPrice(input: 5,  output: 25, estimated: false),
        "claude-opus-4-7":   ModelPrice(input: 5,  output: 25, estimated: false),
        "claude-opus-4-6":   ModelPrice(input: 5,  output: 25, estimated: false),
        "claude-opus-4-5":   ModelPrice(input: 5,  output: 25, estimated: false),
        "claude-sonnet-5":   ModelPrice(input: 3,  output: 15, estimated: false),
        "claude-sonnet-4-6": ModelPrice(input: 3,  output: 15, estimated: false),
        "claude-sonnet-4-5": ModelPrice(input: 3,  output: 15, estimated: false),
        "claude-haiku-4-5":  ModelPrice(input: 1,  output: 5,  estimated: false),
    ]

    /// User overrides from ~/.config/menumon/config.json, loaded at launch.
    static var overrides: [String: ModelPrice] = [:]

    static func price(for model: String) -> ModelPrice {
        if let override = overrides[model] { return override }
        if let exact = published[model] { return exact }

        // Unknown ID (e.g. a model released after this table was written).
        // Fall back to the family's tier and flag it so the UI can say so.
        let name = model.lowercased()
        if name.contains("fable") || name.contains("mythos") {
            return ModelPrice(input: 10, output: 50, estimated: true)
        }
        if name.contains("opus") { return ModelPrice(input: 5, output: 25, estimated: true) }
        if name.contains("sonnet") { return ModelPrice(input: 3, output: 15, estimated: true) }
        if name.contains("haiku") { return ModelPrice(input: 1, output: 5, estimated: true) }
        return ModelPrice(input: 0, output: 0, estimated: true)
    }
}

// MARK: - Records

struct UsageRecord {
    let date: Date
    let model: String
    let project: String
    let sessionID: String
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite5m: Int
    let cacheWrite1h: Int

    var totalTokens: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }

    var cost: Double {
        let p = Pricing.price(for: model)
        return Double(input) / 1_000_000 * p.input
            + Double(output) / 1_000_000 * p.output
            + Double(cacheRead) / 1_000_000 * p.cacheRead
            + Double(cacheWrite5m) / 1_000_000 * p.cacheWrite5m
            + Double(cacheWrite1h) / 1_000_000 * p.cacheWrite1h
    }
}

struct UsageTotals {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var cost = 0.0
    var messages = 0

    var tokens: Int { input + output + cacheRead + cacheWrite }
    /// Tokens excluding cache reads — closer to "work done" than raw throughput.
    var billableWeightedTokens: Int { input + output + cacheWrite }

    mutating func add(_ r: UsageRecord) {
        input += r.input
        output += r.output
        cacheRead += r.cacheRead
        cacheWrite += r.cacheWrite5m + r.cacheWrite1h
        cost += r.cost
        messages += 1
    }
}

struct UsageSnapshot {
    var today = UsageTotals()
    var window = UsageTotals()               // rolling 5 hours
    var windowStart: Date?                   // oldest record inside the window
    var byModelToday: [(model: String, totals: UsageTotals)] = []
    var activeSessions: [(project: String, session: String, lastActivity: Date, cost: Double)] = []
    var hasEstimatedPricing = false
    var totalRecords = 0
    /// Highest cost seen in any 5-hour span over the last 48h — used to auto-scale
    /// the "Claude usage" percentage when the user hasn't set an explicit budget.
    var historicalMaxWindowCost: Double = 0
}

/// There is no API for a subscription plan's real rate-limit quota, so "usage %"
/// has to come from somewhere else: either a budget the user names explicitly, or
/// (by default) how the current 5h window compares to the busiest 5h window seen
/// recently. The latter is a relative "how loaded am I right now" measure, not a
/// true quota fraction — `isAutoCalibrated` tells the UI which one it's showing.
enum UsageBudget {
    static func fraction(snapshot: UsageSnapshot, config: Config) -> Double? {
        guard snapshot.totalRecords > 0 else { return nil }
        if config.fiveHourCostBudget > 0 {
            return snapshot.window.cost / config.fiveHourCostBudget
        }
        if config.fiveHourTokenBudget > 0 {
            return Double(snapshot.window.tokens) / Double(config.fiveHourTokenBudget)
        }
        let ceiling = max(snapshot.historicalMaxWindowCost, snapshot.window.cost, 0.01)
        return snapshot.window.cost / ceiling
    }

    static func isAutoCalibrated(config: Config) -> Bool {
        config.fiveHourCostBudget <= 0 && config.fiveHourTokenBudget <= 0
    }
}

// MARK: - Reader

/// Incrementally tails ~/.claude/projects/**/*.jsonl and aggregates token usage.
final class ClaudeUsageReader {

    static let windowLength: TimeInterval = 5 * 60 * 60

    private let root: URL
    private var offsets: [String: UInt64] = [:]
    private var seenMessageIDs: Set<String> = []
    private var records: [UsageRecord] = []

    private let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")) {
        self.root = root
    }

    /// Reads any bytes appended since the last call and returns fresh aggregates.
    func refresh(now: Date = Date()) -> UsageSnapshot {
        for file in jsonlFiles() {
            ingest(file)
        }
        prune(before: now.addingTimeInterval(-48 * 60 * 60))
        return aggregate(now: now)
    }

    private func jsonlFiles() -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }

    private func ingest(_ url: URL) {
        let key = url.path
        let size = (try? FileManager.default.attributesOfItem(atPath: key)[.size] as? UInt64)
            .flatMap { $0 } ?? 0
        var offset = offsets[key] ?? 0
        if size < offset { offset = 0 }   // file was rotated or truncated
        guard size > offset else { return }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }

        // Only consume through the last complete line; a partially-written trailing
        // line is left for the next refresh.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = data[data.startIndex...lastNewline]
        offsets[key] = offset + UInt64(complete.count)

        let project = url.deletingLastPathComponent().lastPathComponent
        for line in complete.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            if let record = parse(Data(line), project: project) {
                records.append(record)
            }
        }
    }

    private func parse(_ line: Data, project: String) -> UsageRecord? {
        guard let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              root["type"] as? String == "assistant",
              let message = root["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let id = (message["id"] as? String)
            ?? (root["requestId"] as? String)
            ?? (root["uuid"] as? String)
        if let id {
            guard seenMessageIDs.insert(id).inserted else { return nil }
        }

        let stamp = root["timestamp"] as? String ?? ""
        let date = isoWithFraction.date(from: stamp) ?? isoPlain.date(from: stamp) ?? Date()

        let creation = usage["cache_creation"] as? [String: Any]
        let write5m = creation?["ephemeral_5m_input_tokens"] as? Int
        let write1h = creation?["ephemeral_1h_input_tokens"] as? Int
        // Older records only carry the flat total; treat those as 5m writes.
        let flatWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
        let resolved5m = write5m ?? (write1h == nil ? flatWrite : 0)

        return UsageRecord(
            date: date,
            model: message["model"] as? String ?? "unknown",
            project: project,
            sessionID: root["sessionId"] as? String ?? "",
            input: usage["input_tokens"] as? Int ?? 0,
            output: usage["output_tokens"] as? Int ?? 0,
            cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
            cacheWrite5m: resolved5m,
            cacheWrite1h: write1h ?? 0)
    }

    private func prune(before cutoff: Date) {
        guard records.contains(where: { $0.date < cutoff }) else { return }
        records.removeAll { $0.date < cutoff }
    }

    private func aggregate(now: Date) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        snapshot.totalRecords = records.count

        let midnight = Calendar.current.startOfDay(for: now)
        let windowCutoff = now.addingTimeInterval(-Self.windowLength)

        var byModel: [String: UsageTotals] = [:]
        var sessions: [String: (project: String, last: Date, cost: Double)] = [:]

        for record in records {
            if record.date >= midnight {
                snapshot.today.add(record)
                byModel[record.model, default: UsageTotals()].add(record)
                if Pricing.price(for: record.model).estimated {
                    snapshot.hasEstimatedPricing = true
                }
            }
            if record.date >= windowCutoff {
                snapshot.window.add(record)
                if snapshot.windowStart == nil || record.date < snapshot.windowStart! {
                    snapshot.windowStart = record.date
                }
                guard !record.sessionID.isEmpty else { continue }
                var entry = sessions[record.sessionID]
                    ?? (project: record.project, last: record.date, cost: 0)
                entry.last = max(entry.last, record.date)
                entry.cost += record.cost
                sessions[record.sessionID] = entry
            }
        }

        snapshot.byModelToday = byModel
            .map { (model: $0.key, totals: $0.value) }
            .sorted { $0.totals.cost > $1.totals.cost }

        snapshot.historicalMaxWindowCost = Self.maxSlidingWindowCost(records)

        snapshot.activeSessions = sessions
            .map { (project: $0.value.project, session: $0.key,
                    lastActivity: $0.value.last, cost: $0.value.cost) }
            .sorted { $0.lastActivity > $1.lastActivity }

        return snapshot
    }

    /// Max cost summed over any 5-hour span in `records`, via a two-pointer sliding
    /// sum over records sorted by time. O(n log n) for the sort, O(n) for the scan.
    private static func maxSlidingWindowCost(_ records: [UsageRecord]) -> Double {
        let sorted = records.sorted { $0.date < $1.date }
        guard !sorted.isEmpty else { return 0 }

        var left = 0
        var runningCost = 0.0
        var best = 0.0
        for right in sorted.indices {
            runningCost += sorted[right].cost
            while sorted[right].date.timeIntervalSince(sorted[left].date) > windowLength {
                runningCost -= sorted[left].cost
                left += 1
            }
            best = max(best, runningCost)
        }
        return best
    }
}
