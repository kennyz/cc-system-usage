import AppKit

final class PanelViewController: NSViewController {

    static let width: CGFloat = 340

    var onRefresh: (() -> Void)?
    var onQuit: (() -> Void)?
    var onFreeMemory: (() -> Void)?

    enum MemoryCleanupState {
        case running
        case finished(freedBytes: UInt64)
        case failed(String)
    }

    // CPU
    private let cpuValue = UI.label("—", size: 20, weight: .medium, mono: true)
    private let cpuDetail = UI.label("", size: 11, color: .secondaryLabelColor, mono: true)
    private let cpuSpark = SparklineView()

    // Memory
    private let memValue = UI.label("—", size: 20, weight: .medium, mono: true)
    private let memDetail = UI.label("", size: 11, color: .secondaryLabelColor, mono: true)
    private let memBar = BarView()
    private let memPressure = UI.label("", size: 11, color: .secondaryLabelColor, mono: true)
    private lazy var freeMemoryButton = makeButton("Free Up Memory", action: #selector(freeMemoryTapped))
    private let memCleanupStatus = UI.label("", size: 10, color: .secondaryLabelColor)
    private var cleanupStatusClearWorkItem: DispatchWorkItem?

    // Processes — collapsed by default; the header toggles it.
    private let processStack = UI.vstack([], spacing: 3)
    private lazy var processToggle = makeDisclosure(action: #selector(toggleProcesses))
    private var processesExpanded = false

    // Claude
    private let claudeValue = UI.label("—", size: 20, weight: .medium, mono: true)
    private let windowBar = BarView()
    private let claudeDetail = UI.label("", size: 11, color: .secondaryLabelColor, mono: true)
    private let claudeReset = UI.label("", size: 13, weight: .semibold, mono: true)
    private let weeklyValue = UI.label("—", size: 13, weight: .medium, mono: true, align: .right)
    private let weeklyBar = BarView()
    private let weeklyDetail = UI.label("", size: 11, color: .secondaryLabelColor, mono: true)
    private let weeklyResetLabel = UI.label("", size: 13, weight: .semibold, mono: true)
    private let costLine = UI.label("", size: 11, color: .secondaryLabelColor, mono: true)
    private let modelStack = UI.vstack([], spacing: 3)
    private let pricingNote = UI.label("", size: 10, color: .secondaryLabelColor)

    private let footer = UI.label("", size: 10, color: .secondaryLabelColor)

    override func loadView() {
        let content = OpaqueBackgroundView()
        content.wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false

        cpuSpark.translatesAutoresizingMaskIntoConstraints = false
        cpuSpark.heightAnchor.constraint(equalToConstant: 40).isActive = true
        memBar.translatesAutoresizingMaskIntoConstraints = false
        memBar.heightAnchor.constraint(equalToConstant: 6).isActive = true
        windowBar.translatesAutoresizingMaskIntoConstraints = false
        windowBar.heightAnchor.constraint(equalToConstant: 6).isActive = true
        windowBar.tint = Palette.blue
        weeklyBar.translatesAutoresizingMaskIntoConstraints = false
        weeklyBar.heightAnchor.constraint(equalToConstant: 6).isActive = true
        weeklyBar.tint = Palette.blue

        let refreshButton = makeButton("Refresh", action: #selector(refreshTapped))
        let quitButton = makeButton("Quit", action: #selector(quitTapped))
        let footerRow = UI.row([footer, NSView(), refreshButton, quitButton], spacing: 8)
        footerRow.alignment = .centerY

        let cleanupRow = UI.row([freeMemoryButton, memCleanupStatus, NSView()], spacing: 8)
        cleanupRow.alignment = .centerY

        let stack = UI.vstack([
            headerRow("CPU", value: cpuValue),
            cpuSpark,
            cpuDetail,
            UI.separator(),
            headerRow("Memory", value: memValue),
            memBar,
            memDetail,
            memPressure,
            cleanupRow,
            UI.separator(),
            processToggle,
            processStack,
            UI.separator(),
            headerRow("Claude usage", value: claudeValue),
            windowBar,
            claudeReset,
            claudeDetail,
            UI.row([UI.label("All models", size: 12, color: .secondaryLabelColor), NSView(), weeklyValue]),
            weeklyBar,
            weeklyResetLabel,
            weeklyDetail,
            costLine,
            modelStack,
            pricingNote,
            UI.separator(),
            footerRow,
        ], spacing: 8)

        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            content.widthAnchor.constraint(equalToConstant: Self.width),
        ])

        // Full-width children inside a .leading-aligned stack.
        for child in [cpuSpark, memBar, windowBar, weeklyBar, processStack, modelStack, footerRow, cleanupRow]
            as [NSView] {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        view = content
        updateProcessToggle()
    }

    private func headerRow(_ title: String, value: NSView) -> NSStackView {
        let row = UI.row([UI.sectionHeader(title), NSView(), value])
        row.alignment = .lastBaseline
        return row
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        return button
    }

    private func makeDisclosure(action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.imagePosition = .imageLeading
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    private func updateProcessToggle() {
        let symbol = processesExpanded ? "chevron.down" : "chevron.right"
        processToggle.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        processToggle.attributedTitle = NSAttributedString(
            string: " TOP PROCESSES",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        processStack.isHidden = !processesExpanded || processStack.arrangedSubviews.isEmpty
    }

    @objc private func toggleProcesses() {
        processesExpanded.toggle()
        updateProcessToggle()
    }

    /// Bold, colored "resets in …" line — the countdown is the thing people glance
    /// for, so it gets more weight than the secondary detail text.
    private func setReset(_ label: NSTextField, date: Date?, remaining: TimeInterval?) {
        guard let remaining, remaining > 0 else {
            label.stringValue = date == nil ? "⟳ reset time unavailable" : "⟳ reset pending"
            label.textColor = .secondaryLabelColor
            return
        }
        var text = "⟳ resets in \(Fmt.duration(remaining))"
        if let date { text += "  ·  \(Fmt.resetTime(date))" }
        label.stringValue = text
        label.textColor = remaining < 3600 ? Palette.green : Palette.orange
    }

    @objc private func refreshTapped() { onRefresh?() }
    @objc private func quitTapped() { onQuit?() }
    @objc private func freeMemoryTapped() { onFreeMemory?() }

    /// Reflects the free-memory operation's progress. macOS prompts for admin
    /// credentials itself (a native system dialog) — this view never sees them.
    func setMemoryCleanupState(_ state: MemoryCleanupState) {
        cleanupStatusClearWorkItem?.cancel()
        switch state {
        case .running:
            freeMemoryButton.isEnabled = false
            freeMemoryButton.title = "Freeing…"
            memCleanupStatus.stringValue = "Enter your Mac password if prompted"
        case .finished(let freedBytes):
            freeMemoryButton.isEnabled = true
            freeMemoryButton.title = "Free Up Memory"
            memCleanupStatus.stringValue = freedBytes > 50_000_000
                ? "Freed \(Fmt.compactBytes(freedBytes))"
                : "Done — little to reclaim right now"
            scheduleStatusClear()
        case .failed(let message):
            freeMemoryButton.isEnabled = true
            freeMemoryButton.title = "Free Up Memory"
            memCleanupStatus.stringValue = message
            scheduleStatusClear()
        }
    }

    private func scheduleStatusClear() {
        let workItem = DispatchWorkItem { [weak self] in self?.memCleanupStatus.stringValue = "" }
        cleanupStatusClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: workItem)
    }

    // MARK: - Updates

    func update(
        cpu: CPUReading,
        history: [Double],
        memory: MemoryReading,
        processes: [ProcessReading],
        usage: UsageSnapshot,
        planUsage: PlanUsageSample?,
        weeklyReset: Date?,
        config: Config,
        updatedAt: Date
    ) {
        cpuValue.stringValue = Fmt.percent(cpu.total)
        cpuValue.textColor = Palette.load(cpu.total)
        cpuSpark.values = history
        cpuSpark.tint = Palette.load(cpu.total)
        cpuDetail.stringValue = String(
            format: "user %.1f%%  ·  sys %.1f%%  ·  %d cores",
            cpu.user * 100, cpu.system * 100, cpu.perCore.count)

        memValue.stringValue = Fmt.bytes(memory.used)
        memValue.textColor = Palette.load(memory.usedFraction)
        memBar.value = memory.usedFraction
        memDetail.stringValue =
            "\(Fmt.percent(memory.usedFraction)) - \(Fmt.compactBytes(memory.used))"
            + "  ·  app \(Fmt.compactBytes(memory.appMemory))"
            + "  ·  wired \(Fmt.compactBytes(memory.wired))"
            + "  ·  comp \(Fmt.compactBytes(memory.compressed))"
        var pressureText = "pressure \(Fmt.percent(memory.pressure))"
        if memory.swapUsed > 0 {
            pressureText += "  ·  swap \(Fmt.compactBytes(memory.swapUsed))"
        }
        if memory.cachedFiles > 0 {
            pressureText += "  ·  cached \(Fmt.compactBytes(memory.cachedFiles))"
        }
        memPressure.stringValue = pressureText

        rebuild(processStack, with: processes.map { process in
            let name = UI.label(process.command, size: 11)
            let cpuText = UI.label(
                String(format: "%.1f%%", process.cpu), size: 11,
                color: .secondaryLabelColor, mono: true, align: .right)
            let memText = UI.label(
                Fmt.compactBytes(process.residentBytes), size: 11,
                color: .secondaryLabelColor, mono: true, align: .right)
            cpuText.widthAnchor.constraint(equalToConstant: 48).isActive = true
            memText.widthAnchor.constraint(equalToConstant: 52).isActive = true
            let row = UI.row([name, NSView(), cpuText, memText], spacing: 4)
            row.alignment = .firstBaseline
            return row
        })

        updateProcessToggle()

        updateClaude(usage: usage, planUsage: planUsage, weeklyReset: weeklyReset, config: config)

        footer.stringValue = "updated \(Fmt.ago(updatedAt))"
    }

    private func updateClaude(
        usage: UsageSnapshot, planUsage: PlanUsageSample?, weeklyReset: Date?, config: Config
    ) {
        if let planUsage, let weekly = planUsage.weeklyPercent {
            let fraction = Double(weekly) / 100
            weeklyValue.stringValue = "\(weekly)%"
            weeklyValue.textColor = Palette.load(fraction)
            weeklyBar.isHidden = false
            weeklyBar.value = fraction
            weeklyBar.tint = Palette.load(fraction)
            weeklyResetLabel.isHidden = false
            setReset(weeklyResetLabel, date: weeklyReset, remaining: weeklyReset?.timeIntervalSinceNow)
            weeklyDetail.stringValue = ""
            weeklyDetail.isHidden = true
        } else {
            weeklyValue.stringValue = "—"
            weeklyBar.isHidden = true
            weeklyResetLabel.isHidden = true
            weeklyDetail.stringValue = ""
            weeklyDetail.isHidden = true
        }

        if let planUsage, let fh = planUsage.fiveHourPercent {
            // Real number from Claude Code's or the desktop app's own usage cache,
            // whichever is newer (see PlanUsageReader.latest).
            let fraction = Double(fh) / 100
            claudeValue.stringValue = "\(fh)%"
            claudeValue.textColor = Palette.load(fraction)
            windowBar.isHidden = false
            windowBar.value = fraction
            windowBar.tint = Palette.load(fraction)
            let remaining = planUsage.fiveHourRemaining()
            claudeReset.isHidden = false
            setReset(claudeReset, date: Date().addingTimeInterval(remaining), remaining: remaining)
            claudeDetail.stringValue = "as of \(Fmt.ago(planUsage.date))  ·  \(planUsage.source)"
        } else if usage.totalRecords > 0, let fraction = UsageBudget.fraction(snapshot: usage, config: config) {
            // Fallback: the desktop app's cache is missing/stale, but the user has
            // named an explicit budget in config.json.
            claudeValue.stringValue = Fmt.percent(fraction)
            claudeReset.isHidden = true
            claudeValue.textColor = Palette.load(fraction)
            windowBar.isHidden = false
            windowBar.value = fraction
            windowBar.tint = Palette.load(fraction)
            if config.fiveHourCostBudget > 0 {
                claudeDetail.stringValue =
                    "\(Fmt.cost(usage.window.cost)) of \(Fmt.cost(config.fiveHourCostBudget)) budget"
                    + "  ·  no desktop app usage cache found"
            } else {
                claudeDetail.stringValue =
                    "\(Fmt.tokens(usage.window.tokens)) of \(Fmt.tokens(config.fiveHourTokenBudget)) tok budget"
                    + "  ·  no desktop app usage cache found"
            }
        } else {
            // No real quota data available at all. plan-usage-history.json only
            // gets a fresh sample written when you open Claude's Settings → Usage
            // page — it doesn't update continuously like chat does — so it can go
            // stale for days of normal use. Rather than guess, show nothing.
            claudeValue.stringValue = "—"
            claudeReset.isHidden = true
            windowBar.isHidden = true
            claudeDetail.stringValue = "No real quota data — open Claude's Settings → Usage to refresh"
        }

        if usage.totalRecords == 0 {
            costLine.stringValue = ""
            rebuild(modelStack, with: [])
            pricingNote.stringValue = ""
            return
        }

        costLine.stringValue =
            "today \(Fmt.cost(usage.today.cost)) · \(usage.today.messages) msgs"
            + "  ·  \(usage.activeSessions.count) active session(s)"

        rebuild(modelStack, with: usage.byModelToday.prefix(4).map { entry in
            let price = Pricing.price(for: entry.model)
            let name = UI.label(
                entry.model + (price.estimated ? " *" : ""),
                size: 11, color: .secondaryLabelColor)
            let value = UI.label(
                Fmt.cost(entry.totals.cost),
                size: 11, color: .secondaryLabelColor, mono: true, align: .right)
            let row = UI.row([name, NSView(), value], spacing: 4)
            row.alignment = .firstBaseline
            return row
        })

        pricingNote.stringValue = usage.hasEstimatedPricing
            ? "* rate estimated from model family — set it in ~/.config/menumon/config.json"
            : ""
        pricingNote.isHidden = !usage.hasEstimatedPricing
    }

    private func rebuild(_ stack: NSStackView, with rows: [NSView]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for row in rows {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.isHidden = rows.isEmpty
    }
}
