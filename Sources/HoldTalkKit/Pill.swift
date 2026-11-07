import AppKit

/// What the floating pill is showing.
public enum PillContent: Equatable {
    case holding
    case handsFree(secondsLeft: Int, elapsed: Int)
    case transcribing
    /// Esc was pressed: the mic is off and the undo can still be taken.
    case cancelled(hint: String)
    case message(String, isError: Bool)
}

/// The pill's drawing. Light comes from above: a lighter top edge and a small
/// shadow beneath make it read as raised over whatever is behind it.
public final class PillView: NSView {
    public var content: PillContent = .holding { didSet { needsDisplay = true } }
    public var level: Float = 0 { didSet { needsDisplay = true } }
    /// 0...1, drives the recording dot's pulse.
    public var pulse: CGFloat = 1 { didSet { needsDisplay = true } }

    private static let padding: CGFloat = 8
    private static let height: CGFloat = 36
    private static let red = NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1)
    private static let amber = NSColor(srgbRed: 1.0, green: 0.72, blue: 0.2, alpha: 1)
    private static let blue = NSColor(srgbRed: 0.42, green: 0.68, blue: 1.0, alpha: 1)
    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let detailFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    public override var isFlipped: Bool { false }

    private struct Parts {
        var dot: NSColor
        var title: String
        var detail: String?
        var showsMeter: Bool
    }

    private var parts: Parts {
        switch content {
        case .holding:
            return Parts(dot: Self.red, title: "Hold", detail: nil, showsMeter: true)
        case let .handsFree(secondsLeft, elapsed):
            let warning = secondsLeft <= 30
            return Parts(dot: warning ? Self.amber : Self.red,
                         title: "Hands-free",
                         detail: warning ? "stops in \(Self.clock(secondsLeft))" : Self.clock(elapsed),
                         showsMeter: true)
        case .transcribing:
            return Parts(dot: Self.blue, title: "Transcribing", detail: "esc", showsMeter: false)
        case let .cancelled(hint):
            // Amber and still: no pulsing, no meter, the mic is off.
            return Parts(dot: Self.amber, title: "Cancelled", detail: hint, showsMeter: false)
        case let .message(text, isError):
            return Parts(dot: isError ? Self.amber : Self.blue, title: text, detail: nil, showsMeter: false)
        }
    }

    private static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static let shadowMargin: CGFloat = 10
    private static let meterWidth: CGFloat = 34
    private static let maxTitleWidth: CGFloat = 460

    /// Window size for the current content, including room for the shadow.
    public var fittingWindowSize: NSSize {
        let parts = parts
        var width: CGFloat = 16 + 8 + 8
        width += min(Self.maxTitleWidth, textWidth(parts.title, Self.titleFont))
        if let detail = parts.detail { width += 8 + textWidth(detail, Self.detailFont) }
        if parts.showsMeter { width += 10 + Self.meterWidth }
        width += 16
        return NSSize(width: ceil(width) + Self.shadowMargin * 2,
                      height: Self.height + Self.shadowMargin * 2)
    }

    private func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    public override func draw(_ dirtyRect: NSRect) {
        let parts = parts
        let body = bounds.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin)
        let radius = body.height / 2
        let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 6
        shadow.set()
        NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Lit top edge, clipped to the shape so it follows the curve.
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let edge = NSBezierPath(roundedRect: body.offsetBy(dx: 0, dy: -1), xRadius: radius, yRadius: radius)
        let lit = NSBezierPath(rect: body)
        lit.append(edge)
        lit.windingRule = .evenOdd
        NSColor(srgbRed: 0.27, green: 0.27, blue: 0.31, alpha: 1).setFill()
        lit.fill()
        NSGraphicsContext.restoreGraphicsState()

        var x = body.minX + 16
        let dot = NSRect(x: x, y: body.midY - 4, width: 8, height: 8)
        parts.dot.withAlphaComponent(0.45 + 0.55 * pulse).setFill()
        NSBezierPath(ovalIn: dot).fill()
        x += 8 + 8

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: Self.titleFont,
            .foregroundColor: NSColor(white: 0.97, alpha: 1),
        ]
        let titleWidth = min(Self.maxTitleWidth, textWidth(parts.title, Self.titleFont))
        let titleHeight = (parts.title as NSString).size(withAttributes: titleAttributes).height
        (parts.title as NSString).draw(
            with: NSRect(x: x, y: body.midY - titleHeight / 2, width: titleWidth + 1, height: titleHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: titleAttributes)
        x += titleWidth

        if let detail = parts.detail {
            x += 8
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.detailFont,
                .foregroundColor: NSColor(white: 0.66, alpha: 1),
            ]
            let height = (detail as NSString).size(withAttributes: attributes).height
            (detail as NSString).draw(at: NSPoint(x: x, y: body.midY - height / 2), withAttributes: attributes)
            x += textWidth(detail, Self.detailFont)
        }

        if parts.showsMeter {
            x += 10
            drawMeter(startingAt: x, centerY: body.midY)
        }
    }

    private func drawMeter(startingAt startX: CGFloat, centerY: CGFloat) {
        // Speech peaks are small numbers, so a square root spreads them out.
        let loudness = CGFloat(min(1, sqrt(max(0, level)) * 1.5))
        let shape: [CGFloat] = [0.45, 0.8, 1, 0.7, 0.4]
        NSColor(white: 0.9, alpha: 1).setFill()
        for (index, scale) in shape.enumerated() {
            let height = 3 + 13 * loudness * scale
            let bar = NSRect(x: startX + CGFloat(index) * 7, y: centerY - height / 2, width: 3, height: height)
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

/// The floating window. It never takes focus, so typing stays in your app.
@MainActor
public final class PillWindow {
    private let panel: NSPanel
    private let view = PillView()
    private var hideWork: DispatchWorkItem?
    private var pulseTimer: Timer?
    private var pulseClock: Double = 0

    public init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 56),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = view
    }

    public func show(_ content: PillContent) {
        hideWork?.cancel()
        hideWork = nil
        view.content = content
        reposition()
        panel.orderFrontRegardless()
        updatePulse(for: content)
    }

    /// Shows a short note, then hides by itself.
    public func flash(_ text: String, isError: Bool = false) {
        show(.message(text, isError: isError))
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? 4 : 2.5), execute: work)
    }

    public func hide() {
        hideWork?.cancel()
        hideWork = nil
        pulseTimer?.invalidate()
        pulseTimer = nil
        panel.orderOut(nil)
    }

    public func setLevel(_ level: Float) {
        view.level = level
    }

    private func updatePulse(for content: PillContent) {
        pulseTimer?.invalidate()
        pulseTimer = nil
        view.pulse = 1
        switch content {
        case .holding, .handsFree, .transcribing:
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pulseClock += 1.0 / 20
                    self.view.pulse = CGFloat(0.5 + 0.5 * cos(self.pulseClock * 2 * .pi / 1.4))
                }
            }
        case .message, .cancelled:
            break
        }
    }

    private func reposition() {
        let size = view.fittingWindowSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.minY + 14,
                              width: size.width, height: size.height),
                       display: true)
    }
}
