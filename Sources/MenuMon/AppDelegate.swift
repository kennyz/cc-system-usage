import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let historyLength = 40
    private static let cpuInterval: TimeInterval = 2
    private static let memoryInterval: TimeInterval = 60
    private static let usageInterval: TimeInterval = 20
    private static let planUsageInterval: TimeInterval = 15
    private static let weeklyResetInterval: TimeInterval = 120

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let panel = PanelViewController()

    private let sampler = SystemSampler()
    private let usageReader = ClaudeUsageReader()
    private let usageQueue = DispatchQueue(label: "menumon.usage", qos: .utility)

    private var config = Config.load()
    private var history: [Double] = []
    private var cpu = CPUReading()
    private var memory = MemoryReading()
    private var processes: [ProcessReading] = []
    private var usage = UsageSnapshot()
    private var planUsage: PlanUsageSample?
    private var weeklyReset: Date?
    private var lastUpdate = Date()
    private var usageInFlight = false
    private var memoryCleanupInFlight = false

    private var cpuTimer: Timer?
    private var memoryTimer: Timer?
    private var usageTimer: Timer?
    private var planUsageTimer: Timer?
    private var weeklyResetTimer: Timer?
    private var weeklyResetInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .noImage  // icons are embedded in attributedTitle instead
        }

        popover.behavior = .transient
        popover.animates = false
        panel.onRefresh = { [weak self] in
            self?.sampleCPU()
            self?.sampleMemory()
            self?.sampleUsage()
            self?.samplePlanUsage()
            self?.sampleWeeklyReset()
        }
        panel.onQuit = { NSApp.terminate(nil) }
        panel.onFreeMemory = { [weak self] in self?.freeMemory() }
        popover.contentViewController = panel

        _ = sampler.sampleCPU()  // prime the tick baseline; first delta needs two reads
        sampleCPU()
        sampleMemory()
        sampleUsage()
        samplePlanUsage()
        sampleWeeklyReset()

        cpuTimer = Timer.scheduledTimer(
            withTimeInterval: Self.cpuInterval, repeats: true
        ) { [weak self] _ in self?.sampleCPU() }

        memoryTimer = Timer.scheduledTimer(
            withTimeInterval: Self.memoryInterval, repeats: true
        ) { [weak self] _ in self?.sampleMemory() }

        usageTimer = Timer.scheduledTimer(
            withTimeInterval: Self.usageInterval, repeats: true
        ) { [weak self] _ in self?.sampleUsage() }

        planUsageTimer = Timer.scheduledTimer(
            withTimeInterval: Self.planUsageInterval, repeats: true
        ) { [weak self] _ in self?.samplePlanUsage() }

        weeklyResetTimer = Timer.scheduledTimer(
            withTimeInterval: Self.weeklyResetInterval, repeats: true
        ) { [weak self] _ in self?.sampleWeeklyReset() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cpuTimer?.invalidate()
        memoryTimer?.invalidate()
        usageTimer?.invalidate()
        planUsageTimer?.invalidate()
        weeklyResetTimer?.invalidate()
    }

    // MARK: - Sampling

    /// Drives the panel's CPU section and top-process list. Does not touch the menu
    /// bar — the bar only shows Claude usage % and memory %.
    private func sampleCPU() {
        if let reading = sampler.sampleCPU() {
            cpu = reading
            history.append(reading.total)
            if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        }
        if popover.isShown {
            processes = sampler.sampleTopProcesses()
        }
        lastUpdate = Date()
        if popover.isShown { refreshPanel() }
    }

    /// Runs once a minute, as requested — memory doesn't need finer granularity and
    /// this keeps the menu bar redraw (and the syscalls behind it) infrequent.
    private func sampleMemory() {
        memory = sampler.sampleMemory()
        lastUpdate = Date()
        updateStatusBarTitle()
        if popover.isShown { refreshPanel() }
    }

    /// Tailing is incremental — only bytes appended since the last pass are parsed —
    /// so this stays cheap enough to run on a timer whether or not the panel is open.
    private func sampleUsage() {
        guard !usageInFlight else { return }
        usageInFlight = true
        usageQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.usageReader.refresh()
            DispatchQueue.main.async {
                self.usage = snapshot
                self.usageInFlight = false
                self.lastUpdate = Date()
                self.updateStatusBarTitle()
                if self.popover.isShown { self.refreshPanel() }
            }
        }
    }

    /// Cheap file read (a few KB of JSON) — safe to poll frequently on the main thread.
    private func samplePlanUsage() {
        planUsage = PlanUsageReader.latest()
        updateStatusBarTitle()
        if popover.isShown { refreshPanel() }
    }

    /// Scans an IndexedDB log file (currently under 1MB, but no upper bound
    /// guaranteed) off the main thread, on a slower cadence than the JSON reads.
    private func sampleWeeklyReset() {
        guard !weeklyResetInFlight else { return }
        weeklyResetInFlight = true
        usageQueue.async { [weak self] in
            let reset = SevenDayWindow.nextReset()
            DispatchQueue.main.async {
                guard let self else { return }
                self.weeklyReset = reset
                self.weeklyResetInFlight = false
                if self.popover.isShown { self.refreshPanel() }
            }
        }
    }

    /// Runs macOS's own `purge` tool (evicts inactive/file-backed pages) to reclaim
    /// memory. `purge` requires root, so this shells out through `osascript ...
    /// "with administrator privileges"` — that's Apple's own elevation path: macOS
    /// shows its native authentication dialog and the password never passes through
    /// this app's code at all. Note `purge` mainly affects file cache and purgeable
    /// pages, not memory already wired to running apps, so effect size varies.
    private func freeMemory() {
        guard !memoryCleanupInFlight else { return }
        memoryCleanupInFlight = true
        let before = memory.used
        panel.setMemoryCleanupState(.running)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [
                "-e", "do shell script \"/usr/sbin/purge\" with administrator privileges",
            ]
            process.standardOutput = FileHandle.nullDevice
            let errorPipe = Pipe()
            process.standardError = errorPipe

            var succeeded = false
            var errorText = ""
            do {
                try process.run()
                process.waitUntilExit()
                succeeded = process.terminationStatus == 0
                if !succeeded {
                    let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    errorText = String(data: data, encoding: .utf8) ?? ""
                }
            } catch {
                errorText = error.localizedDescription
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.memoryCleanupInFlight = false
                self.memory = self.sampler.sampleMemory()
                self.updateStatusBarTitle()
                if succeeded {
                    let after = self.memory.used
                    let freed = before > after ? before - after : 0
                    self.panel.setMemoryCleanupState(.finished(freedBytes: freed))
                } else {
                    let cancelled = errorText.contains("-128") || errorText.lowercased().contains("cancel")
                    self.panel.setMemoryCleanupState(
                        .failed(cancelled ? "Cancelled" : "Failed — admin access required"))
                }
                if self.popover.isShown { self.refreshPanel() }
            }
        }
    }

    // MARK: - UI

    /// Real quota percentage when the Claude desktop app's own cache has it (see
    /// PlanUsageReader); falls back to a configured budget, then to nil — never a
    /// synthesized estimate (see UsageBudget's doc comment for why).
    private func claudeUsageFraction() -> Double? {
        if let fh = planUsage?.fiveHourPercent { return Double(fh) / 100 }
        return UsageBudget.fraction(snapshot: usage, config: config)
    }

    private func updateStatusBarTitle() {
        let countdown = Fmt.countdown(FiveHourWindow.timeRemaining())
        statusItem.button?.attributedTitle = StatusBarRenderer.title(
            claudeFraction: claudeUsageFraction(), resetCountdown: countdown,
            memoryFraction: memory.usedFraction)
    }

    private func refreshPanel() {
        panel.update(
            cpu: cpu,
            history: history,
            memory: memory,
            processes: processes,
            usage: usage,
            planUsage: planUsage,
            weeklyReset: weeklyReset,
            config: config,
            updatedAt: lastUpdate)
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        config = Config.load()
        processes = sampler.sampleTopProcesses()
        memory = sampler.sampleMemory()
        planUsage = PlanUsageReader.latest()
        refreshPanel()
        updateStatusBarTitle()
        sampleUsage()
        sampleWeeklyReset()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Reload config", action: #selector(reloadConfig), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Open config folder", action: #selector(openConfig), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MenuMon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func reloadConfig() {
        config = Config.load()
        updateStatusBarTitle()
        if popover.isShown { refreshPanel() }
    }

    @objc private func openConfig() {
        let folder = Config.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: Config.url.path) {
            let template = """
            {
              "pricing": {
                "claude-opus-5": { "input": 5, "output": 25 }
              },
              "fiveHourCostBudget": 0,
              "fiveHourTokenBudget": 0
            }

            """
            try? template.write(to: Config.url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.activateFileViewerSelecting([Config.url])
    }
}
