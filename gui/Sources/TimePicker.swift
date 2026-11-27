// The 24-hour clock control: a value field with one stepper column.

import Cocoa

extension AppDelegate {
    /// A 24-hour clock-time control: one value, one pair of arrows, no date and
    /// no AM/PM. The stock `textFieldAndStepper` is exactly that, and it keeps
    /// the arrows acting on the whole value instead of one segment.
    func timePicker(_ clock: String) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        picker.locale = Locale(identifier: "en_GB")
        picker.dateValue = date(fromClock: clock)
        picker.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        picker.target = self
        picker.action = #selector(timesChanged)
        picker.widthAnchor.constraint(equalToConstant: 96).isActive = true
        picker.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return picker
    }

    /// `"22:00"` from the config becomes a date on a fixed reference day; only
    /// the time of day is ever read back.
    func date(fromClock clock: String) -> Date {
        var components = DateComponents(year: 2001, month: 1, day: 1)
        let parts = clock.split(separator: ":")
        components.hour = parts.count == 2 ? Int(parts[0]) : 22
        components.minute = parts.count == 2 ? Int(parts[1]) : 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: components) ?? Date()
    }

    /// `"22:00"`, zero padded, as the config file and the agent use it.
    func clock(from date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    @objc func timesChanged() {
        guard !busy else { return }
        // Ignore a gesture that lands on the value the agent already runs, so
        // a click that changes nothing does not write the same schedule again.
        let off = clock(from: offPicker.dateValue)
        let on = clock(from: onPicker.dateValue)
        if let status = sendToAgent("status"),
           off == status["off"] as? String, on == status["on"] as? String
        {
            return
        }
        autoSave("schedule \(off) \(on)")
    }
}
