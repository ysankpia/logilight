// Sending a command to the agent and reporting what came back.

import Cocoa

extension AppDelegate {
    func run(_ command: String, describe: String) {
        busy = true
        guard let reply = sendToAgent(command) else {
            busy = false
            present(String(format: strings.notRunning, describe))
            return
        }
        if let error = reply["error"] as? String {
            busy = false
            present(error)
            return
        }
        // Clear the flag first: refresh() skips while a command is in flight.
        busy = false
        refresh()
    }

    func present(_ message: String) {
        let alert = NSAlert()
        alert.messageText = strings.windowTitle
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc func lightStateChanged() {
        // Setting the segment programmatically is not an editing gesture.
        guard !busy else { return }
        let text = strings
        switch lightStateControl.selectedSegment {
        case 0: run("auto", describe: text.actionScheduled)
        case 1: run("on", describe: text.actionOn)
        case 2: run("off", describe: text.actionOff)
        default: return
        }
    }
}
