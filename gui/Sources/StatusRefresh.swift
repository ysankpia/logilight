// Reading the agent's status and putting it on screen.

import Cocoa

extension AppDelegate {
    func refresh() {
        guard !busy else { return }
        let text = strings
        // The window can be hidden while the refresh timer keeps running, so
        // only touch the window's controls when there is a window to touch.
        guard window != nil, statusLabel != nil else { return }

        // The "now" mark moves whether or not the agent answers.
        let now = Date()
        nightBar.nowMinutes = minutes(of: now)
        nowLabel.stringValue = text.nowPrefix + " " + clock(from: now)

        guard let status = sendToAgent("status") else {
            statusLabel.stringValue = text.agentDown
            detailLabel.stringValue = String(format: text.agentDownHint, Int(getuid()))
            permissionLabel.isHidden = true
            statusDot.layer?.backgroundColor = Palette.dotOff.cgColor
            lastLabel.stringValue = ""
            updateStatusItem(phase: nil)
            return
        }

        let phase = status["phase"] as? String ?? "on"
        let manual = status["manual"] as? Bool ?? false
        let device = status["device"] as? String ?? "—"
        let permission = status["permission"] as? Bool ?? false
        let off = status["off"] as? String ?? "22:00"
        let on = status["on"] as? String ?? "07:00"
        let devices = status["devices"] as? [String] ?? []

        updateStatusItem(phase: phase)
        // The headline states the situation. With no device answering, the
        // clock's phase says nothing about the LEDs, so say that instead of
        // claiming they are off.
        statusLabel.stringValue = devices.isEmpty
            ? text.statusNoDevice
            : (phase == "off" ? text.statusOffLine : text.statusOnLine)
        // The one accent in the window: amber means the LEDs are on.
        statusDot.layer?.backgroundColor = (devices.isEmpty || phase == "off"
            ? Palette.dotOff
            : Palette.accent).cgColor

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
        // schedule is in charge.
        busy = true
        lightStateControl.selectedSegment = manual ? (phase == "off" ? 2 : 1) : 0
        busy = false

        permissionLabel.stringValue = text.noPermission
        permissionLabel.isHidden = permission

        nightBar.onMinutes = minutes(ofClock: on)
        nightBar.offMinutes = minutes(ofClock: off)

        let action = actionName(status["action"] as? String ?? "")
        let updated = status["updated"] as? String
        let when = clock(from: readableDate(updated) ?? now)
        lastLabel.stringValue = String(format: text.lastAction, action, when)

        // The agent is the source of truth, so the pickers follow it, except
        // while the user is mid-edit or a save is in flight.
        if !editingTimes, !busy {
            offPicker.dateValue = date(fromClock: off)
            onPicker.dateValue = date(fromClock: on)
        }
    }

    /// Minutes past midnight for the bar.
    func minutes(of date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    func minutes(ofClock clock: String) -> Int {
        let parts = clock.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return 0
        }
        return hour * 60 + minute
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
        case "scheduled", "startup": return text.actionScheduled
        case "manual": return text.actionManual
        default: return raw.isEmpty ? "—" : raw
        }
    }

    func readableDate(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: iso) {
            return date
        }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: iso)
    }

    func readable(_ iso: String?) -> String {
        guard let date = readableDate(iso) else { return strings.never }
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
