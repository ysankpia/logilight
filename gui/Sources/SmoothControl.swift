// The smooth-scrolling row: one switch, one duration, and the counters the
// agent keeps so a stuck tap is visible before it is felt.

import Cocoa

extension AppDelegate {
    /// Read the smoothing state once, when the window appears.
    func loadSmooth() {
        guard let reply = sendToAgent("smooth") else { return }
        guard reply["error"] == nil else { return }
        let enabled = reply["enabled"] as? Bool ?? false
        let duration = reply["duration_ms"] as? Int ?? 300
        smoothSwitch.state = enabled ? .on : .off
        smoothSlider.doubleValue = Double(duration)
        smoothValue.stringValue = "\(duration) ms"
    }

    /// Switch smoothing on or off.
    ///
    /// The window cannot read another process's TCC state, so it asks the agent
    /// first. Without Accessibility the switch goes back off and the
    /// Accessibility pane opens: the alert explains, then the settings window
    /// lands on the page the user needs.
    @objc func smoothToggled() {
        let wanted = smoothSwitch.state == .on
        guard let status = sendToAgent("smooth") else {
            present(String(format: strings.notRunning, strings.rowSmooth))
            smoothSwitch.state = wanted ? .off : .on
            return
        }
        if wanted, status["accessibility"] as? Bool == false {
            smoothSwitch.state = .off
            present(strings.smoothNeedsAccessibility)
            openAccessibility()
            return
        }
        guard let reply = sendToAgent(wanted ? "smooth on" : "smooth off") else {
            present(String(format: strings.notRunning, strings.rowSmooth))
            smoothSwitch.state = wanted ? .off : .on
            return
        }
        if reply["error"] != nil {
            smoothSwitch.state = wanted ? .off : .on
            present(strings.smoothNeedsAccessibility)
            openAccessibility()
            return
        }
        smoothValue.stringValue = "\(reply["duration_ms"] as? Int ?? 300) ms"
    }

    /// Store the new duration; the agent clamps it to a sane range.
    @objc func smoothDurationChanged() {
        let milliseconds = Int(smoothSlider.doubleValue.rounded())
        guard let reply = sendToAgent("smooth duration \(milliseconds)") else { return }
        if let error = reply["error"] as? String {
            present("\(strings.actionFailed)：\(error)")
            return
        }
        let applied = reply["duration_ms"] as? Int ?? milliseconds
        smoothSlider.doubleValue = Double(applied)
        smoothValue.stringValue = "\(applied) ms"
    }

    /// How far one click of − or + moves the duration.
    private static let durationStep = 25.0

    @objc func smoothStepDown() {
        stepSmoothDuration(by: -Self.durationStep)
    }

    @objc func smoothStepUp() {
        stepSmoothDuration(by: Self.durationStep)
    }

    /// Move the slider by one step and save it, so the value is always a round
    /// number instead of whatever the pointer happened to land on.
    private func stepSmoothDuration(by delta: Double) {
        let next = min(
            max(smoothSlider.doubleValue + delta, smoothSlider.minValue),
            smoothSlider.maxValue
        )
        guard next != smoothSlider.doubleValue else { return }
        smoothSlider.doubleValue = next
        smoothDurationChanged()
    }
}
