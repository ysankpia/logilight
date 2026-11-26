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

    /// Switch smoothing on or off. On asks the agent to install the tap; if
    /// Accessibility is missing the agent reports that instead of pretending.
    @objc func smoothToggled() {
        let wanted = smoothSwitch.state == .on
        guard let reply = sendToAgent(wanted ? "smooth on" : "smooth off") else {
            present(strings.notRunning)
            smoothSwitch.state = wanted ? .off : .on
            return
        }
        if let error = reply["error"] as? String {
            present(error)
            smoothSwitch.state = wanted ? .off : .on
            return
        }
        if wanted, reply["accessibility"] as? Bool == false {
            present(strings.smoothNeedsAccessibility)
            smoothSwitch.state = .off
            _ = sendToAgent("smooth off")
            return
        }
        smoothValue.stringValue = "\(reply["duration_ms"] as? Int ?? 300) ms"
    }

    /// Store the new duration; the agent clamps it to a sane range.
    @objc func smoothDurationChanged() {
        let milliseconds = Int(smoothSlider.doubleValue.rounded())
        guard let reply = sendToAgent("smooth duration \(milliseconds)") else { return }
        if let error = reply["error"] as? String {
            present(error)
            return
        }
        let applied = reply["duration_ms"] as? Int ?? milliseconds
        smoothSlider.doubleValue = Double(applied)
        smoothValue.stringValue = "\(applied) ms"
    }
}
