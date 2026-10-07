import AppKit

// MARK: - Formatting

enum Fmt {
    static func bytes(_ value: UInt64) -> String {
        let gb = Double(value) / 1_073_741_824
        if gb >= 10 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(value) / 1_048_576)
    }

    static func compactBytes(_ value: UInt64) -> String {
        let gb = Double(value) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1fG", gb) }
        return String(format: "%.0fM", Double(value) / 1_048_576)
    }

    static func tokens(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    static func cost(_ value: Double) -> String {
        if value >= 100 { return String(format: "$%.0f", value) }
        if value >= 1 { return String(format: "$%.2f", value) }
        return String(format: "$%.3f", value)
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }

    static func ago(_ date: Date, from now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "\(max(seconds, 0))s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m ago"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0))
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    /// Local wall-clock time of a reset: "16:00" today, "Sun 19:00" within a week.
    static func resetTime(_ date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }

    /// "04:10" style countdown for the menu bar.
    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 3600, (total % 3600) / 60)
    }
}

// MARK: - Load colors

enum Palette {
    /// Deeper than the stock system colors, which wash out on light backgrounds;
    /// dark mode keeps the brighter variants so they still pop on dark gray.
    static let green = dynamic(light: 0x1A7F37, dark: 0x30D158)
    static let orange = dynamic(light: 0xB35900, dark: 0xFF9F0A)
    static let red = dynamic(light: 0xC4161C, dark: 0xFF453A)
    static let blue = dynamic(light: 0x0A5FD6, dark: 0x409CFF)

    /// Green below 60%, amber to 85%, red above.
    static func load(_ fraction: Double) -> NSColor {
        switch fraction {
        case ..<0.60: return green
        case ..<0.85: return orange
        default: return red
        }
    }

    private static func dynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
        }
    }
}

// MARK: - Sparkline

final class SparklineView: NSView {
    var values: [Double] = [] { didSet { needsDisplay = true } }
    var tint: NSColor = Palette.blue

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        guard values.count > 1, rect.width > 0, rect.height > 0 else { return }

        let step = rect.width / CGFloat(values.count - 1)
        func point(_ index: Int) -> CGPoint {
            let clamped = min(max(values[index], 0), 1)
            return CGPoint(
                x: rect.minX + CGFloat(index) * step,
                y: rect.maxY - CGFloat(clamped) * rect.height)
        }

        let fill = NSBezierPath()
        fill.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for i in values.indices { fill.line(to: point(i)) }
        fill.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
        fill.close()
        tint.withAlphaComponent(0.18).setFill()
        fill.fill()

        let line = NSBezierPath()
        line.move(to: point(0))
        for i in 1..<values.count { line.line(to: point(i)) }
        line.lineWidth = 1.5
        line.lineJoinStyle = .round
        tint.setStroke()
        line.stroke()
    }
}

// MARK: - Bar

final class BarView: NSView {
    var value: Double = 0 { didSet { needsDisplay = true } }
    var tint: NSColor? { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 6) }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.tertiaryLabelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let clamped = min(max(value, 0), 1)
        guard clamped > 0 else { return }
        let width = max(bounds.height, bounds.width * CGFloat(clamped))
        (tint ?? Palette.load(clamped)).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
            xRadius: radius, yRadius: radius
        ).fill()
    }
}

// MARK: - Icon tinting

extension NSImage {
    /// Recolors a template (alpha-mask) image by compositing a solid color through
    /// its alpha channel. SF Symbols work well with this.
    func tinted(_ color: NSColor) -> NSImage {
        let result = NSImage(size: size)
        result.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: size)
        draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        rect.fill(using: .sourceAtop)
        result.unlockFocus()
        return result
    }
}

// MARK: - Menu bar title

enum StatusBarRenderer {
    private static func symbol(_ names: [String], pointSize: CGFloat) -> NSImage? {
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
                return image.withSymbolConfiguration(config)
            }
        }
        return nil
    }

    private static var claudeIcon: NSImage? { symbol(["bolt.fill", "c.circle.fill"], pointSize: 11) }
    private static var memoryIcon: NSImage? { symbol(["memorychip", "memorychip.fill"], pointSize: 11) }

    /// Builds "[icon] 70% · 04:10  [icon] 50%" for the menu bar button's
    /// attributedTitle. `claudeFraction` is nil until the first usage read
    /// completes (or there is no Claude Code history at all), in which case it
    /// renders as "—". `resetCountdown` is the "HH:MM" left in the current 5-hour
    /// rate-limit window (see FiveHourWindow) — shown regardless of whether
    /// `claudeFraction` resolved, since it's computed from the wall clock alone.
    static func title(
        claudeFraction: Double?, resetCountdown: String, memoryFraction: Double
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        // Text and icons are always white.
        let color = NSColor.white

        func appendGroup(icon: NSImage?, text: String) {
            if let icon {
                let attachment = NSTextAttachment()
                attachment.image = icon.tinted(color)
                attachment.bounds = CGRect(x: 0, y: -2.5, width: 12, height: 12)
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(string: " "))
            }
            result.append(NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: color]))
        }

        appendGroup(icon: claudeIcon, text: claudeFraction.map(Fmt.percent) ?? "—")
        result.append(NSAttributedString(
            string: " · \(resetCountdown)",
            attributes: [.font: font, .foregroundColor: color]))
        result.append(NSAttributedString(string: "  "))
        appendGroup(icon: memoryIcon, text: Fmt.percent(memoryFraction))

        return result
    }
}

// MARK: - Small builders

enum UI {
    static func label(
        _ text: String = "",
        size: CGFloat = 12,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor,
        mono: Bool = false,
        align: NSTextAlignment = .left
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = mono
            ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.alignment = align
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    static func sectionHeader(_ text: String) -> NSTextField {
        label(text.uppercased(), size: 10, weight: .semibold, color: .secondaryLabelColor)
    }

    static func row(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.alignment = .firstBaseline
        stack.distribution = .fill
        return stack
    }

    static func vstack(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = spacing
        stack.alignment = .leading
        return stack
    }

    static func separator() -> NSView {
        let view = NSBox()
        view.boxType = .separator
        return view
    }
}

/// Solid panel background. NSPopover's default material is translucent, which lets
/// whatever is behind the popover tint the panel and muddy the colored numbers.
final class OpaqueBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
}
