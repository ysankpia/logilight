// Reading the agent's status and putting it on screen.

import Cocoa

extension AppDelegate {
    func refresh() {
        guard !busy else { return }
        let text = strings
        // The window can be hidden while the refresh timer keeps running, so
        // only touch the window's controls when there is a window to touch.
        guard window != nil, statusLabel != nil else { return }
        guard let status = sendToAgent("status") else {
            statusLabel.stringValue = text.agentDown
            detailLabel.stringValue = String(format: text.agentDownHint, Int(getuid()))
            permissionLabel.isHidden = true
            scheduleValue.stringValue = "—"
            actionValue.stringValue = "—"
            updateStatusItem(phase: nil)
            return
        }
        let phase = status["phase"] as? String ?? "on"
        let manual = status["manual"] as? Bool ?? false
        let device = status["device"] as? String ?? "—"
        let permission = status["permission"] as? Bool ?? false
        let off = status["off"] as? String ?? "?"
        let on = status["on"] as? String ?? "?"

        let devices = status["devices"] as? [String] ?? []
        updateStatusItem(phase: phase)
        // The headline states the situation; the schedule lives in the stats
        // strip, so nothing here reads as a button to press. With no device
        // answering, the clock's phase says nothing about the LEDs, so say that
        // instead of claiming they are off.
        statusLabel.stringValue = devices.isEmpty
            ? text.statusNoDevice
            : (phase == "off" ? text.statusOffLine : text.statusOnLine)

        var detail = devices.isEmpty ? text.statusNoDevice : device
        if manual {
            detail += " · " + text.manualHold
        } else if let next = status["next"] as? String, !next.isEmpty {
            detail += " · " + String(format: text.nextChange, readable(next))
        } else {
            detail += " · " + String(format: text.scheduleLine, off, on)
        }
        detailLabel.stringValue = detail

        // The selector mirrors reality, and shows nothing selected while the
        // schedule is in charge: "Off"/"On" mean "hold this until tomorrow".
        busy = true
        if manual {
            lightStateControl.selectedSegment = phase == "off" ? 2 : 1
        } else {
            lightStateControl.selectedSegment = 0
        }
        busy = false

        permissionLabel.stringValue = text.noPermission
        permissionLabel.isHidden = permission

        scheduleValue.stringValue = "\(off) → \(on)"
        actionValue.stringValue = "\(actionName(status["action"] as? String ?? "")) · \(readable(status["updated"] as? String))"

        // The agent is the source of truth, so the pickers follow it, except
        // while the user is mid-edit or a save is in flight. That window is
        // what keeps a 2-second refresh from fighting the stepper.
        if !editingTimes, !busy {
            offPicker.dateValue = date(fromClock: status["off"] as? String ?? "22:00")
            onPicker.dateValue = date(fromClock: status["on"] as? String ?? "07:00")
        }
    }

    /// Keep the menu bar item honest: a tooltip names the current state, and the
    /// icon dims when the lights are off, so the menu bar alone tells the story.
    func updateStatusItem(phase: String?) {
        guard let button = statusItem?.button else { return }
        let text = strings
        switch phase {
        case "off":
            button.appearsDisabled = true
            button.toolTip = text.statusOffLine
        case "on":
            button.appearsDisabled = false
            button.toolTip = text.statusOnLine
        default:
            button.appearsDisabled = false
            button.toolTip = text.agentDown
        }
    }

    func actionName(_ raw: String) -> String {
        let text = strings
        switch raw {
        case "scheduled": return text.actionScheduled
        case "manual": return text.actionManual
        default: return raw.isEmpty ? "—" : raw
        }
    }

    func readable(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return strings.never }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = parser.date(from: iso)
        if date == nil {
            parser.formatOptions = [.withInternetDateTime]
            date = parser.date(from: iso)
        }
        guard let date else { return iso }
        let formatter = DateFormatter()
        formatter.locale = locale()
        formatter.dateFormat = DateFormatter.dateFormat(
            fromTemplate: "EEE d MMM HH:mm",
            options: 0,
            locale: locale()
        )
        return formatter.string(from: date)
    }
}
