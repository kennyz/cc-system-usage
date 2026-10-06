import AppKit

// `MenuMon --dump` prints the same numbers the panel shows and exits. Useful for
// sanity-checking the aggregation against the raw transcripts without the UI.
if CommandLine.arguments.contains("--dump") {
    let config = Config.load()
    let sampler = SystemSampler()
    _ = sampler.sampleCPU()
    Thread.sleep(forTimeInterval: 0.4)
    let cpu = sampler.sampleCPU()
    let memory = sampler.sampleMemory()
    let usage = ClaudeUsageReader().refresh()
    let planUsage = PlanUsageReader.latest()

    print("CPU     \(Fmt.percent(cpu?.total ?? 0))  (\(cpu?.perCore.count ?? 0) cores)")
    print("Memory  \(Fmt.percent(memory.usedFraction))"
        + "  (\(Fmt.bytes(memory.used)) / \(Fmt.bytes(memory.total)))"
        + "  pressure \(Fmt.percent(memory.pressure))")
    print("")
    let remaining = planUsage?.fiveHourRemaining() ?? FiveHourWindow.timeRemaining()
    let resetSource = planUsage?.fiveHourReset.map { "server resets_at \($0)" }
        ?? "fixed UTC grid, next boundary \(FiveHourWindow.nextReset())"
    print("Resets in  \(Fmt.countdown(remaining))  (\(Fmt.duration(remaining)))  — \(resetSource)")
    if let planUsage, let fh = planUsage.fiveHourPercent {
        print("Claude 5h usage  \(fh)%  (real, from \(planUsage.source), as of \(Fmt.ago(planUsage.date)))"
            + (planUsage.weeklyPercent.map { "  ·  weekly \($0)%" } ?? ""))
    } else if let fraction = UsageBudget.fraction(snapshot: usage, config: config) {
        print("Claude 5h usage  \(Fmt.percent(fraction))  (no desktop app cache — using configured budget)")
    } else {
        print("Claude 5h usage  —  (no desktop app cache, no configured budget — open"
            + " Claude's Settings → Usage to refresh the cache)")
    }
    if let weeklyReset = planUsage?.weeklyReset {
        print("Weekly (all models) resets in \(Fmt.duration(weeklyReset.timeIntervalSinceNow))"
            + "  — at \(weeklyReset)  (from \(planUsage?.source ?? ""))")
    } else if let weeklyReset = SevenDayWindow.nextReset() {
        print("Weekly (all models) resets in \(Fmt.duration(weeklyReset.timeIntervalSinceNow))"
            + "  — at \(weeklyReset)  (parsed from IndexedDB, best-effort)")
    } else {
        print("Weekly reset time: unavailable (couldn't find/parse it in IndexedDB)")
    }
    print("")
    print("Claude records loaded: \(usage.totalRecords)")
    print("5h win  \(Fmt.cost(usage.window.cost))  \(usage.window.messages) msgs"
        + "  \(usage.activeSessions.count) session(s)"
        + "  ·  busiest 5h seen: \(Fmt.cost(usage.historicalMaxWindowCost))")
    print("Today   \(Fmt.cost(usage.today.cost))  \(usage.today.messages) msgs")
    for entry in usage.byModelToday {
        let price = Pricing.price(for: entry.model)
        print("  \(entry.model)  \(Fmt.cost(entry.totals.cost))"
            + "  [$\(price.input)/$\(price.output) per MTok"
            + (price.estimated ? ", ESTIMATED]" : "]"))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
