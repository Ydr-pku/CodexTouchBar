import AppKit

final class CompactHUDViewController: NSViewController, NSTouchBarDelegate {
    private enum TouchBarIdentifiers {
        static let touchBar = NSTouchBar.CustomizationIdentifier("com.jackchen.TouchBarCodexToken.compactHUD.touchBar")
        static let limits = NSTouchBarItem.Identifier("com.jackchen.TouchBarCodexToken.compactHUD.limits")
    }

    private let hudView: CompactQuotaHUDView
    private lazy var touchBarView = TouchBarRateLimitsView(
        closeTarget: self,
        closeAction: #selector(quitClicked),
        showsCloseButton: false
    )
    private var currentState = RateLimitDisplayState.initial
    private let onRefresh: () -> Void
    private let onQuit: () -> Void

    init(initialAppearance: HUDAppearance, onRefresh: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.onRefresh = onRefresh
        self.onQuit = onQuit
        self.hudView = CompactQuotaHUDView(
            initialAppearance: initialAppearance,
            onRefresh: onRefresh,
            onQuit: onQuit
        )
        super.init(nibName: nil, bundle: nil)
        self.hudView.touchBarProvider = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = hudView
        view.frame = NSRect(x: 0, y: 0, width: 134, height: 34)
        update(with: currentState)
    }

    override func makeTouchBar() -> NSTouchBar? {
        makeQuotaTouchBar()
    }

    func makeQuotaTouchBar() -> NSTouchBar {
        let touchBar = NSTouchBar()
        touchBar.customizationIdentifier = TouchBarIdentifiers.touchBar
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [TouchBarIdentifiers.limits]
        return touchBar
    }

    func activateTouchBar() {
        guard TouchBarPresentationEnvironment.hasActiveBuiltInDisplay else {
            return
        }
        hudView.activateTouchBar()
    }

    func presentQuotaDetails() {
        guard TouchBarPresentationEnvironment.hasActiveBuiltInDisplay else {
            return
        }
        hudView.activateTouchBar()
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case TouchBarIdentifiers.limits:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = touchBarView
            return item
        default:
            return nil
        }
    }

    func update(with state: RateLimitDisplayState) {
        currentState = state

        guard isViewLoaded else {
            return
        }

        hudView.update(with: state)
        touchBarView.update(with: state)
    }

    func updateAppearance(_ appearance: HUDAppearance) {
        hudView.updateAppearance(appearance)
    }

    @objc private func quitClicked() {
        onQuit()
    }
}

private enum TouchBarPresentationEnvironment {
    static var hasActiveBuiltInDisplay: Bool {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[screenNumberKey] as? NSNumber,
               CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0 {
                return true
            }
        }
        return false
    }
}

final class CompactQuotaHUDView: NSView {
    private enum Layout {
        static let compactSize = NSSize(width: 134, height: 34)
        static let expandedSize = NSSize(width: 700, height: 34)
    }

    private enum HorizontalExpansionAnchor {
        case left
        case center
        case right
    }

    weak var touchBarProvider: CompactHUDViewController?

    private let quotaItem = CompactQuotaItemView()
    private let refreshButton = CompactIconButton(
        symbolName: "arrow.clockwise",
        accessibilityLabel: "刷新额度"
    )
    private let quitButton = CompactIconButton(
        symbolName: "xmark",
        accessibilityLabel: "退出额度条"
    )
    private let onRefresh: () -> Void
    private let onQuit: () -> Void
    private var hudAppearance: HUDAppearance
    private var widthConstraint: NSLayoutConstraint?
    private var compactStack: NSStackView?
    private var detailsView: TouchBarRateLimitsView!
    private var expansionAnchor = HorizontalExpansionAnchor.center
    private var mouseDownScreenLocation: NSPoint?
    private var windowOriginAtMouseDown: NSPoint?
    private var didDrag = false
    private var hoverTrackingArea: NSTrackingArea?
    private var hoverExitTimer: Timer?
    private var hoverContainmentFrame: NSRect?
    private var pointerIsInside = false

    init(initialAppearance: HUDAppearance, onRefresh: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.onRefresh = onRefresh
        self.onQuit = onQuit
        self.hudAppearance = initialAppearance
        super.init(frame: .zero)
        detailsView = TouchBarRateLimitsView(
            closeTarget: self,
            closeAction: #selector(collapseClicked),
            showsCloseButton: false
        )
        detailsView.appearance = NSAppearance(named: .darkAqua)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        if window == nil {
            stopHoverExitMonitor()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        pointerIsInside = true
        startHoverExitMonitor()
        expandForHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        pointerIsInside = true
        startHoverExitMonitor()
        expandForHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        handlePointerExit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else {
            return nil
        }

        if detailsView.isHidden {
            let refreshPoint = refreshButton.convert(point, from: self)
            let quitPoint = quitButton.convert(point, from: self)
            if refreshButton.bounds.contains(refreshPoint) || quitButton.bounds.contains(quitPoint) {
                return super.hitTest(point)
            }
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownScreenLocation = NSEvent.mouseLocation
        windowOriginAtMouseDown = window?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startLocation = mouseDownScreenLocation,
              let startOrigin = windowOriginAtMouseDown,
              let window else {
            return
        }

        let currentLocation = NSEvent.mouseLocation
        let deltaX = currentLocation.x - startLocation.x
        let deltaY = currentLocation.y - startLocation.y
        if hypot(deltaX, deltaY) >= 4 {
            didDrag = true
        }
        if didDrag {
            window.setFrameOrigin(NSPoint(x: startOrigin.x + deltaX, y: startOrigin.y + deltaY))
            if var containmentFrame = hoverContainmentFrame {
                containmentFrame.origin = window.frame.origin
                hoverContainmentFrame = containmentFrame
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag {
            touchBarProvider?.presentQuotaDetails()
        }
        mouseDownScreenLocation = nil
        windowOriginAtMouseDown = nil
        didDrag = false
        if !pointerIsInside {
            collapseDetails(animated: true)
            stopHoverExitMonitor()
        }
    }

    override func makeTouchBar() -> NSTouchBar? {
        touchBarProvider?.makeQuotaTouchBar()
    }

    func activateTouchBar() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        touchBar = nil
        touchBar = makeTouchBar()
    }

    func update(with state: RateLimitDisplayState) {
        quotaItem.update(with: state.weekly ?? state.fiveHour)
        detailsView.update(with: state)
        toolTip = state.statusText
    }

    func showDetails() {
        guard detailsView.isHidden else {
            return
        }

        expansionAnchor = preferredExpansionAnchor()
        hoverContainmentFrame = targetWindowFrame(for: Layout.expandedSize)
        compactStack?.isHidden = true
        detailsView.isHidden = false
        widthConstraint?.constant = Layout.expandedSize.width
        resizeWindow(to: Layout.expandedSize, animated: true)
    }

    func collapseDetails(animated: Bool) {
        guard !detailsView.isHidden else {
            return
        }

        detailsView.isHidden = true
        compactStack?.isHidden = false
        widthConstraint?.constant = Layout.compactSize.width
        hoverContainmentFrame = nil
        resizeWindow(to: Layout.compactSize, animated: animated)
    }

    func updateAppearance(_ appearance: HUDAppearance) {
        self.hudAppearance = appearance
        layer?.backgroundColor = appearance.backgroundColor.cgColor
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = hudAppearance.backgroundColor.cgColor
        layer?.cornerRadius = 17
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false

        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        quitButton.target = self
        quitButton.action = #selector(quitClicked)

        let stack = NSStackView(views: [quotaItem, refreshButton, quitButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 8
        compactStack = stack

        addSubview(stack)
        addSubview(detailsView)
        detailsView.isHidden = true

        let widthConstraint = widthAnchor.constraint(equalToConstant: Layout.compactSize.width)
        self.widthConstraint = widthConstraint

        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: Layout.compactSize.height),
            quotaItem.widthAnchor.constraint(equalToConstant: 52),
            refreshButton.widthAnchor.constraint(equalToConstant: 20),
            refreshButton.heightAnchor.constraint(equalToConstant: 20),
            quitButton.widthAnchor.constraint(equalToConstant: 20),
            quitButton.heightAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.widthAnchor.constraint(equalToConstant: 108),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailsView.centerXAnchor.constraint(equalTo: centerXAnchor),
            detailsView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func resizeWindow(to size: NSSize, animated: Bool) {
        guard let window else {
            frame.size = size
            return
        }

        guard let targetFrame = targetWindowFrame(for: size) else {
            return
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(targetFrame, display: true)
            }
        } else {
            window.setFrame(targetFrame, display: true)
        }
    }

    private func targetWindowFrame(for size: NSSize) -> NSRect? {
        guard let window else {
            return nil
        }

        let currentFrame = window.frame
        let targetX: CGFloat
        switch expansionAnchor {
        case .left:
            targetX = currentFrame.minX
        case .center:
            targetX = currentFrame.midX - size.width / 2
        case .right:
            targetX = currentFrame.maxX - size.width
        }
        return NSRect(
            x: targetX,
            y: currentFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func expandForHover(at point: NSPoint) {
        guard detailsView.isHidden else {
            return
        }

        let refreshPoint = refreshButton.convert(point, from: self)
        let quitPoint = quitButton.convert(point, from: self)
        if refreshButton.bounds.contains(refreshPoint) || quitButton.bounds.contains(quitPoint) {
            return
        }
        showDetails()
    }

    private func startHoverExitMonitor() {
        guard hoverExitTimer == nil else {
            return
        }

        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self, let window = self.window else {
                self?.stopHoverExitMonitor()
                return
            }
            let containmentFrame = self.hoverContainmentFrame ?? window.frame
            if !containmentFrame.contains(NSEvent.mouseLocation) {
                self.handlePointerExit()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverExitTimer = timer
    }

    private func stopHoverExitMonitor() {
        hoverExitTimer?.invalidate()
        hoverExitTimer = nil
    }

    private func handlePointerExit() {
        pointerIsInside = false
        guard mouseDownScreenLocation == nil else {
            return
        }
        collapseDetails(animated: true)
        stopHoverExitMonitor()
    }

    private func preferredExpansionAnchor() -> HorizontalExpansionAnchor {
        guard let window else {
            return .center
        }

        let screenFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let relativeX = window.frame.midX - screenFrame.minX
        let third = screenFrame.width / 3

        if relativeX < third {
            return .left
        }
        if relativeX > third * 2 {
            return .right
        }
        return .center
    }

    @objc private func refreshClicked() {
        onRefresh()
    }

    @objc private func quitClicked() {
        onQuit()
    }

    @objc private func collapseClicked() {
        collapseDetails(animated: true)
    }
}

private final class CompactQuotaItemView: NSView {
    private let label = NSTextField(labelWithString: "--")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(with meter: LimitMeter?) {
        guard let meter else {
            label.stringValue = "--"
            label.textColor = NSColor.white.withAlphaComponent(0.62)
            return
        }

        let remaining = Int(meter.remainingPercent.rounded())
        label.stringValue = "\(remaining)%"
        label.textColor = .white
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false

        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

private final class CompactIconButton: NSButton {
    init(symbolName: String, accessibilityLabel: String) {
        super.init(frame: .zero)

        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        contentTintColor = NSColor.white.withAlphaComponent(0.88)
        toolTip = accessibilityLabel
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class CompactStatusDotView: NSView {
    var color = NSColor.systemGreen {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
    }
}
