import AppKit

final class TouchBarRateLimitsView: NSView {
    private let closeButton = NSButton()
    private let chatGPTIconView = NSImageView()
    private let usageChartsView = TokenUsageChartsView()
    private let quotaSummaryView = TouchBarQuotaSummaryView()

    init(closeTarget: AnyObject, closeAction: Selector) {
        super.init(frame: .zero)
        closeButton.target = closeTarget
        closeButton.action = closeAction
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(with state: RateLimitDisplayState) {
        usageChartsView.update(with: state.tokenUsage)
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

        let content = NSStackView(views: [closeButton, chatGPTIconView, usageChartsView, quotaSummaryView])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 6

        addSubview(content)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 620),
            heightAnchor.constraint(equalToConstant: 30),
            closeButton.widthAnchor.constraint(equalToConstant: 30),
            closeButton.heightAnchor.constraint(equalToConstant: 28),
            chatGPTIconView.widthAnchor.constraint(equalToConstant: 30),
            chatGPTIconView.heightAnchor.constraint(equalToConstant: 30),
            usageChartsView.widthAnchor.constraint(equalToConstant: 310),
            usageChartsView.heightAnchor.constraint(equalToConstant: 30),
            quotaSummaryView.widthAnchor.constraint(equalToConstant: 230),
            quotaSummaryView.heightAnchor.constraint(equalToConstant: 27),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private static func chatGPTIcon() -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: "/Applications/ChatGPT.app")
        image.size = NSSize(width: 28, height: 28)
        return image
    }
}

private final class TokenUsageChartsView: NSView {
    private var dailyTokens = Array(repeating: 0, count: 7)
    private var hourlyTokens = Array(repeating: 0, count: 24)

    override var isFlipped: Bool {
        true
    }

    func update(with usage: TokenUsageSummary?) {
        dailyTokens = normalized(usage?.dailyTokens, count: 7)
        hourlyTokens = normalized(usage?.hourlyTokens, count: 24)
        toolTip = makeToolTip()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        drawLabel("近7日", in: NSRect(x: 0, y: 0, width: 32, height: bounds.height))
        drawBars(
            dailyTokens,
            in: NSRect(x: 34, y: 2, width: 84, height: 26),
            highlightIndex: 6,
            futureStartIndex: nil,
            color: .systemTeal
        )

        NSColor.separatorColor.withAlphaComponent(0.55).setFill()
        NSRect(x: 124, y: 3, width: 1, height: 24).fill()

        drawLabel("今日", in: NSRect(x: 130, y: 0, width: 28, height: bounds.height))
        let currentHour = Calendar.current.component(.hour, from: Date())
        drawBars(
            hourlyTokens,
            in: NSRect(x: 160, y: 2, width: 148, height: 26),
            highlightIndex: currentHour,
            futureStartIndex: currentHour + 1,
            color: .systemGreen
        )
    }

    private func drawLabel(_ text: String, in rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .medium),
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

        let spacing: CGFloat = values.count > 12 ? 1 : 2
        let barWidth = max(1, (rect.width - CGFloat(values.count - 1) * spacing) / CGFloat(values.count))
        let maximum = max(1, values.max() ?? 0)

        for (index, value) in values.enumerated() {
            let ratio = CGFloat(value) / CGFloat(maximum)
            let barHeight = value == 0 ? 1 : max(2, ratio * rect.height)
            let x = rect.minX + CGFloat(index) * (barWidth + spacing)
            let barRect = NSRect(x: x, y: rect.maxY - barHeight, width: barWidth, height: barHeight)
            let path = NSBezierPath(roundedRect: barRect, xRadius: min(1.5, barWidth / 2), yRadius: 1.5)

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

    private func makeToolTip() -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let daily = formatter.string(from: NSNumber(value: dailyTokens.reduce(0, +))) ?? "0"
        let today = formatter.string(from: NSNumber(value: hourlyTokens.reduce(0, +))) ?? "0"
        return "近 7 日 \(daily) tokens，今日 \(today) tokens"
    }
}

private final class TouchBarQuotaSummaryView: NSView {
    private let fiveHourRow = TouchBarQuotaSummaryRow(title: "5h")
    private let weeklyRow = TouchBarQuotaSummaryRow(title: "7d")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(fiveHour: LimitMeter?, weekly: LimitMeter?) {
        fiveHourRow.update(with: fiveHour)
        weeklyRow.update(with: weekly)
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false

        let rows = NSStackView(views: [fiveHourRow, weeklyRow])
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 1

        addSubview(rows)

        NSLayoutConstraint.activate([
            fiveHourRow.widthAnchor.constraint(equalToConstant: 230),
            weeklyRow.widthAnchor.constraint(equalToConstant: 230),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}

private final class TouchBarQuotaSummaryRow: NSView {
    private let baseTitle: String
    private let titleLabel: NSTextField
    private let resetLabel = NSTextField(labelWithString: "-- 重置")

    init(title: String) {
        baseTitle = title
        titleLabel = NSTextField(labelWithString: "\(title) --")
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(with meter: LimitMeter?) {
        guard let meter else {
            titleLabel.stringValue = "\(baseTitle) --"
            titleLabel.textColor = .secondaryLabelColor
            resetLabel.stringValue = "-- 重置"
            return
        }

        titleLabel.stringValue = "\(baseTitle) \(meter.remainingText)"
        titleLabel.textColor = color(for: meter.remainingPercent)
        resetLabel.stringValue = meter.resetText
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        titleLabel.lineBreakMode = .byClipping

        resetLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        resetLabel.textColor = .secondaryLabelColor
        resetLabel.alignment = .right
        resetLabel.lineBreakMode = .byClipping

        let row = NSStackView(views: [titleLabel, resetLabel])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4

        addSubview(row)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 13),
            titleLabel.widthAnchor.constraint(equalToConstant: 60),
            resetLabel.widthAnchor.constraint(equalToConstant: 166),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
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
