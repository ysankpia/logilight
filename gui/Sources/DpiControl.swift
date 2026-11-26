// The DPI row: one slider, one value, and the device's own range.

import Cocoa

extension AppDelegate {
    /// Read the pointer's DPI once, when the window appears.
    ///
    /// Polling it would open the HID device every refresh for a value that only
    /// changes when someone moves this slider, so the window asks once and
    /// afterwards trusts the reply it got from the last write.
    func loadDpi() {
        guard let reply = sendToAgent("dpi") else { return }
        guard reply["error"] == nil else { return }
        let current = reply["current"] as? Int ?? 0
        let minimum = reply["min"] as? Int ?? 100
        let maximum = reply["max"] as? Int ?? 25600
        dpiSlider.minValue = Double(minimum)
        dpiSlider.maxValue = Double(maximum)
        dpiSlider.doubleValue = Double(current)
        dpiValue.stringValue = "\(current)"
    }

    /// Write the slider's value. The agent snaps it to a value the device lists
    /// and reads it back, so the label always shows what the mouse took.
    @objc func dpiChanged() {
        let target = Int(dpiSlider.doubleValue.rounded())
        guard let reply = sendToAgent("dpi \(target)") else {
            present(strings.notRunning)
            return
        }
        if let error = reply["error"] as? String {
            present(error)
            return
        }
        let applied = reply["current"] as? Int ?? target
        dpiSlider.doubleValue = Double(applied)
        dpiValue.stringValue = "\(applied)"
    }
}
