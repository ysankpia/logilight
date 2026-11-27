// The one moment in the window: a 24 hour track where amber is "lights on".
//
// The off window usually crosses midnight, so the lit span sits in the middle
// and both ends are dark. A hairline marks the current time.

import Cocoa

final class NightBarView: NSView {
    /// Local wall clock minutes, 0..<1440.
    var onMinutes: Int = 7 * 60 {
        didSet { needsDisplay = true }
    }

    var offMinutes: Int = 22 * 60 {
        didSet { needsDisplay = true }
    }

    var nowMinutes: Int = 0 {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 32)
    }

    override func draw(_: NSRect) {
        let bar = NSRect(x: 0, y: 0, width: bounds.width, height: 4)
        Palette.raisedStrong.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()

        Palette.accent.setFill()
        for span in litSpans() {
            let start = x(for: span.lowerBound, in: bar.width)
            let end = x(for: span.upperBound, in: bar.width)
            NSBezierPath(roundedRect: NSRect(x: start, y: 0, width: end - start, height: 4),
                         xRadius: 2, yRadius: 2).fill()
        }

        Palette.secondary.setFill()
        let nowX = x(for: nowMinutes, in: bar.width)
        NSRect(x: nowX, y: -3, width: 1, height: 10).fill()

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: Palette.muted,
        ]
        drawLabel(clock(onMinutes), at: onMinutes, width: bar.width, attributes: labelAttributes)
        drawLabel(clock(offMinutes), at: offMinutes, width: bar.width, attributes: labelAttributes)
    }

    /// The minutes of the day where the lights are on, as one or two ranges.
    private func litSpans() -> [ClosedRange<Int>] {
        let on = min(max(onMinutes, 0), 1440)
        let off = min(max(offMinutes, 0), 1440)
        if on == off {
            return on == 0 ? [0 ... 1440] : []
        }
        return on < off ? [on ... off] : [on ... 1440, 0 ... off]
    }

    private func x(for minutes: Int, in width: CGFloat) -> CGFloat {
        width * CGFloat(min(max(minutes, 0), 1440)) / 1440
    }

    private func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60 % 24, minutes % 60)
    }

    private func drawLabel(
        _ text: String,
        at minutes: Int,
        width: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let size = (text as NSString).size(withAttributes: attributes)
        let center = x(for: minutes, in: width)
        let x = min(max(center - size.width / 2, 0), width - size.width)
        (text as NSString).draw(at: NSPoint(x: x, y: 12), withAttributes: attributes)
    }
}
