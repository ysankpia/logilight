// The 24-hour clock control: two segments, one arrow column each.

import Cocoa

extension AppDelegate {
    /// A 24-hour clock-time control: two spin segments, no date, no AM/PM.
    ///
    /// The stock `textFieldAndStepper` puts a single pair of arrows on the right
    /// edge, and with two segments those arrows act on the *last* one, so the
    /// arrow beside `22` would change the minutes. This builds one column of
    /// arrows per segment instead: up adds an hour or a minute, down removes
    /// one, and the order matches the text left to right.
    func timePicker(_ clock: String, _ rowOut: inout NSView!) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textField
        picker.datePickerElements = .hourMinute
        picker.locale = Locale(identifier: "en_GB")
        picker.dateValue = date(fromClock: clock)
        picker.target = self
        picker.action = #selector(timesChanged)
        picker.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let columns = NSStackView()
        columns.orientation = .horizontal
        columns.spacing = 3
        for tag in 0 ... 1 {
            let stepper = NSStepper()
            stepper.tag = tag
            stepper.minValue = -1
            stepper.maxValue = 1
            stepper.increment = 1
            stepper.valueWraps = false
            stepper.autorepeat = true
            stepper.target = self
            stepper.action = #selector(stepperClicked(_:))
            stepper.widthAnchor.constraint(equalToConstant: 14).isActive = true
            columns.addArrangedSubview(stepper)
            steppers[ObjectIdentifier(stepper)] = (picker, tag)
        }

        let row = NSStackView(views: [picker, columns])
        row.orientation = .horizontal
        row.spacing = 2
        rowOut = row
        return picker
    }

    /// Each arrow belongs to one segment: column 0 steps the hour, column 1 the
    /// minute, and the direction of the click is the sign of the change.
    @objc func stepperClicked(_ stepper: NSStepper) {
        guard !busy, let (picker, part) = steppers[ObjectIdentifier(stepper)] else { return }
        let delta: TimeInterval = (part == 0 ? 3600 : 60) * (stepper.doubleValue < 0 ? -1 : 1)
        picker.dateValue = picker.dateValue.addingTimeInterval(delta)
        // Reset so the next click starts from zero again and the sign is
        // read from the click itself.
        stepper.doubleValue = 0
        timesChanged()
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
