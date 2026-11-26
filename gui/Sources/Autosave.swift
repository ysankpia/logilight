// The window saves itself; there is no Save button to forget to press.

import Cocoa

extension AppDelegate {
    // MARK: - Autosave

    /// The window saves itself; there is no Save button to forget to press.
    func autoSave(_ command: String) {
        guard !busy else { return }
        busy = true
        // A save started from the pickers holds them still until the answer is
        // in, so a refresh cannot rewind the value the user just chose.
        let touchesTimes = command.hasPrefix("schedule ")
        if touchesTimes {
            editingTimes = true
        }
        defer {
            if touchesTimes {
                finishEditingTimes()
            }
        }
        guard let reply = sendToAgent(command) else {
            busy = false
            present(String(format: strings.notRunning, strings.actionSave))
            return
        }
        if let error = reply["error"] as? String {
            busy = false
            present(error)
            return
        }
        flashSaved()
        busy = false
        refresh()
    }

    /// Release the pickers once a save round trip is over, after the short
    /// pause that lets a stepper click settle. The next refresh then shows
    /// whatever the agent actually stored.
    func finishEditingTimes() {
        savedTimer?.invalidate()
        savedTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.editingTimes = false
            self.refresh()
        }
    }

    func flashSaved() {
        savedLabel.stringValue = strings.autoSaved
        savedLabel.isHidden = false
        savedTimer?.invalidate()
        savedTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            self?.savedLabel.isHidden = true
        }
    }

    func saveRestore() {
        let mode = modePopup.indexOfSelectedItem == 1 ? "fixed" : "captured"
        autoSave("restore \(mode) \(hexString(colorWell.color))")
    }

    @objc func modeChanged() {
        saveRestore()
    }

    /// Picking a colour stores it and applies it, the way the well previously
    /// needed a separate "apply" click.
    @objc func colourChanged() {
        guard !busy else { return }
        let hex = hexString(colorWell.color)
        autoSave("restore \(modePopup.indexOfSelectedItem == 1 ? "fixed" : "captured") \(hex)")
        run("color \(hex)", describe: strings.actionColour)
    }

    @objc func applyColor() {
        run("color \(hexString(colorWell.color))", describe: strings.actionColour)
    }

    @objc func openPrivacy() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    /// The pane that grants the event tap. Smoothing is the only feature that
    /// needs Accessibility, so its row opens this one directly.
    @objc func openAccessibility() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc func restartAgent() {
        let domain = "gui/\(getuid())/com.luhui.logilight"
        var status = launchctl(["kickstart", "-k", domain])
        if status != 0 {
            let plist = NSHomeDirectory() + "/Library/LaunchAgents/com.luhui.logilight.plist"
            status = launchctl(["bootstrap", "gui/\(getuid())", plist])
        }
        if status != 0 {
            present(strings.agentDownHint)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            self?.refresh()
        }
    }
}
