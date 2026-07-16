import AppKit

final class TouchBarRateLimitsView: NSView {
    private let closeButton = NSButton()
    private let showsCloseButton: Bool
    private let chatGPTIconView = NSImageView()
    private let accountDailyChartView = TokenUsageChartView(kind: .accountThirtyDays)
    private let dailyChartView = TokenUsageChartView(kind: .thirtyDays)
    private let hourlyChartView = TokenUsageChartView(kind: .todayHours)
    private let quotaSummaryView = TouchBarQuotaSummaryView()

    init(closeTarget: AnyObject, closeAction: Selector, showsCloseButton: Bool = true) {
        self.showsCloseButton = showsCloseButton
        super.init(frame: .zero)
        closeButton.target = closeTarget
        closeButton.action = closeAction
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(with state: RateLimitDisplayState) {
        accountDailyChartView.update(with: state.accountTokenUsage)
        dailyChartView.update(with: state.tokenUsage)
        hourlyChartView.update(with: state.tokenUsage)
        quotaSummaryView.update(fiveHour: state.fiveHour, weekly: state.weekly)
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false

        closeButton.title = "×"
        closeButton.bezelStyle = .circular
        closeButton.font = .systemFont(ofSize: 19, weight: .semibold)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        chatGPTIconView.image = Self.chatGPTIcon()
        chatGPTIconView.imageAlignment = .alignCenter
        chatGPTIconView.imageScaling = .scaleProportionallyUpOrDown
        chatGPTIconView.translatesAutoresizingMaskIntoConstraints = false
        chatGPTIconView.toolTip = "ChatGPT"

        var contentViews: [NSView] = []
        if showsCloseButton {
            contentViews.append(closeButton)
        }
        contentViews.append(contentsOf: [
            chatGPTIconView,
            accountDailyChartView,
            dailyChartView,
            hourlyChartView,
            quotaSummaryView
        ])
        let content = NSStackView(views: contentViews)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 6

        addSubview(content)

        let segmentWidth: CGFloat = showsCloseButton ? 132.5 : 141.5

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 620),
            heightAnchor.constraint(equalToConstant: 30),
            chatGPTIconView.widthAnchor.constraint(equalToConstant: 30),
            chatGPTIconView.heightAnchor.constraint(equalToConstant: 30),
            accountDailyChartView.widthAnchor.constraint(equalToConstant: segmentWidth),
            accountDailyChartView.heightAnchor.constraint(equalToConstant: 30),
            dailyChartView.widthAnchor.constraint(equalToConstant: segmentWidth),
            dailyChartView.heightAnchor.constraint(equalToConstant: 30),
            hourlyChartView.widthAnchor.constraint(equalToConstant: segmentWidth),
            hourlyChartView.heightAnchor.constraint(equalToConstant: 30),
            quotaSummaryView.widthAnchor.constraint(equalToConstant: segmentWidth),
            quotaSummaryView.heightAnchor.constraint(equalToConstant: 27),
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        if showsCloseButton {
            NSLayoutConstraint.activate([
                closeButton.widthAnchor.constraint(equalToConstant: 30),
                closeButton.heightAnchor.constraint(equalToConstant: 28)
            ])
        }
    }

    private static func chatGPTIcon() -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: "/Applications/ChatGPT.app")
        image.size = NSSize(width: 28, height: 28)
        return image
    }
}

private final class TokenUsageChartView: NSView {
    enum Kind {
        case accountThirtyDays
        case thirtyDays
        case todayHours
    }

    private let kind: Kind
    private var values: [Int]
    private var oneHourTokens = 0
    private var yesterdayTokens = 0

    init(kind: Kind) {
        self.kind = kind
        switch kind {
        case .accountThirtyDays, .thirtyDays:
            self.values = Array(repeating: 0, count: 30)
        case .todayHours:
            self.values = Array(repeating: 0, count: 24)
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    func update(with usage: TokenUsageSummary?) {
        oneHourTokens = usage?.oneHourTokens ?? 0
        switch kind {
        case .accountThirtyDays:
            break
        case .thirtyDays:
            values = normalized(usage?.dailyTokens, count: 30)
            yesterdayTokens = usage?.yesterdayTokens ?? 0
        case .todayHours:
            values = normalized(usage?.hourlyTokens, count: 24)
        }
        toolTip = makeToolTip()
        needsDisplay = true
    }

    func update(with usage: AccountTokenUsage?) {
        guard kind == .accountThirtyDays else {
            return
        }
        values = normalized(usage?.dailyTokens, count: 30)
        yesterdayTokens = values[28]
        toolTip = makeToolTip()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let currentHour = Calendar.current.component(.hour, from: Date())
        let highlightedIndex: Int
        let futureStartIndex: Int?
        let caption: String
        let color: NSColor

        switch kind {
        case .accountThirtyDays:
            highlightedIndex = 29
            futureStartIndex = nil
            caption = "账户30日 \(compactTokenText(values.reduce(0, +))) 昨\(compactTokenText(yesterdayTokens))"
            color = .systemBlue
        case .thirtyDays:
            highlightedIndex = 29
            futureStartIndex = nil
            caption = "本机30日 \(compactTokenText(values.reduce(0, +))) 昨\(compactTokenText(yesterdayTokens))"
            color = .systemTeal
        case .todayHours:
            highlightedIndex = currentHour
            futureStartIndex = currentHour + 1
            caption = "今 \(compactTokenText(values.reduce(0, +)))  近1h \(compactTokenText(oneHourTokens))"
            color = .systemGreen
        }

        let chartInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 8)
        let chartWidth = max(0, bounds.width - chartInsets.left - chartInsets.right)

        drawCaption(caption, in: NSRect(x: 0, y: 0, width: bounds.width - chartInsets.right, height: 10))
        drawBars(
            values,
            in: NSRect(x: chartInsets.left, y: 11, width: chartWidth, height: 17),
            highlightIndex: highlightedIndex,
            futureStartIndex: futureStartIndex,
            color: color
        )

        NSColor.separatorColor.withAlphaComponent(0.6).setFill()
        NSRect(x: bounds.maxX - 1, y: 3, width: 1, height: 24).fill()
    }

    private func drawCaption(_ text: String, in rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        let size = text.size(withAttributes: attributes)
        let textRect = NSRect(
            x: rect.minX,
            y: rect.midY - size.height / 2,
            width: rect.width,
            height: size.height
        )
        text.draw(in: textRect, withAttributes: attributes)
    }

    private func drawBars(
        _ values: [Int],
        in rect: NSRect,
        highlightIndex: Int,
        futureStartIndex: Int?,
        color: NSColor
    ) {
        guard !values.isEmpty else {
            return
        }

        let barWidth: CGFloat = 4
        let occupiedByBars = CGFloat(values.count) * barWidth
        let spacing = values.count > 1
            ? max(0, (rect.width - occupiedByBars) / CGFloat(values.count - 1))
            : 0
        let chartWidth = occupiedByBars + CGFloat(values.count - 1) * spacing
        let startX = rect.minX + (rect.width - chartWidth) / 2
        let maximum = max(1, values.max() ?? 0)

        for (index, value) in values.enumerated() {
            let ratio = CGFloat(value) / CGFloat(maximum)
            let barHeight = value == 0 ? 1 : max(2, ratio * rect.height)
            let x = startX + CGFloat(index) * (barWidth + spacing)
            let barRect = NSRect(x: x, y: rect.maxY - barHeight, width: barWidth, height: barHeight)
            let path = NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5)

            if let futureStartIndex, index >= futureStartIndex {
                NSColor.separatorColor.withAlphaComponent(0.18).setFill()
            } else if index == highlightIndex {
                NSColor.systemYellow.setFill()
            } else if value == 0 {
                color.withAlphaComponent(0.18).setFill()
            } else {
                color.withAlphaComponent(0.82).setFill()
            }
            path.fill()
        }
    }

    private func normalized(_ values: [Int]?, count: Int) -> [Int] {
        guard let values else {
            return Array(repeating: 0, count: count)
        }
        return Array((values + Array(repeating: 0, count: count)).prefix(count))
    }

    private func compactTokenText(_ tokens: Int) -> String {
        let millions = Double(tokens) / 1_000_000
        if millions >= 100 {
            return String(format: "%.0fM", millions)
        }
        if millions >= 10 {
            return String(format: "%.1fM", millions)
        }
        return String(format: "%.2fM", millions)
    }

    private func makeToolTip() -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let total = formatter.string(from: NSNumber(value: values.reduce(0, +))) ?? "0"
        switch kind {
        case .accountThirtyDays:
            return "账户近 30 日 \(total) tokens"
        case .thirtyDays:
            return "本机近 30 日 \(total) tokens"
        case .todayHours:
            return "本机今日 \(total) tokens"
        }
    }
}

private final class TouchBarQuotaSummaryView: NSView {
    private var meter: LimitMeter?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    func update(fiveHour: LimitMeter?, weekly: LimitMeter?) {
        meter = weekly ?? fiveHour
        toolTip = meter.map { "\($0.title)：Token 剩余 \($0.remainingText)，\($0.resetText)" }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let tokenPercent = meter?.remainingPercent ?? 0
        drawBar(
            in: NSRect(x: 4, y: 1, width: max(0, bounds.width - 8), height: 12),
            percent: tokenPercent,
            text: meter.map { "Token \(Int($0.remainingPercent.rounded()))%" } ?? "Token --",
            color: color(for: tokenPercent)
        )

        let time = remainingTime(for: meter)
        drawBar(
            in: NSRect(x: 4, y: 15, width: max(0, bounds.width - 8), height: 12),
            percent: time?.percent ?? 0,
            text: time.map { "Time \(Int($0.percent.rounded()))% · \($0.text)" } ?? "Time --",
            color: .systemBlue
        )
    }

    private func drawBar(in rect: NSRect, percent: Double, text: String, color: NSColor) {
        let background = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        NSColor.separatorColor.withAlphaComponent(0.22).setFill()
        background.fill()

        let ratio = CGFloat(max(0, min(100, percent)) / 100)
        if ratio > 0 {
            let fillRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width * ratio, height: rect.height)
            let fill = NSBezierPath(roundedRect: fillRect, xRadius: 3, yRadius: 3)
            color.withAlphaComponent(0.72).setFill()
            fill.fill()
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let textSize = text.size(withAttributes: attributes)
        let textRect = NSRect(
            x: rect.minX,
            y: rect.midY - textSize.height / 2,
            width: rect.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: attributes)
    }

    private func remainingTime(for meter: LimitMeter?) -> (percent: Double, text: String)? {
        guard
            let meter,
            let resetDate = meter.resetDate,
            let durationMinutes = meter.durationMinutes,
            durationMinutes > 0
        else {
            return nil
        }

        let remainingSeconds = max(0, resetDate.timeIntervalSinceNow)
        let percent = max(0, min(100, remainingSeconds / (durationMinutes * 60) * 100))
        return (percent, compactDuration(remainingSeconds))
    }

    private func compactDuration(_ seconds: TimeInterval) -> String {
        if seconds >= 86_400 {
            let days = Int(seconds / 86_400)
            let hours = (seconds - Double(days) * 86_400) / 3_600
            return "\(days)d\(String(format: "%.1f", hours))h"
        }
        if seconds >= 3_600 {
            return String(format: "%.1fh", seconds / 3_600)
        }
        return "\(Int(ceil(seconds / 60)))m"
    }

    private func color(for remaining: Double) -> NSColor {
        if remaining <= 20 {
            return .systemRed
        }
        if remaining <= 45 {
            return .systemYellow
        }
        return .systemGreen
    }
}
