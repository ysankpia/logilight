// The settings window and the small view helpers it is built from.

import Cocoa

extension AppDelegate {
    func label(_ text: String, bold: Bool = false, size: CGFloat = 13) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        return field
    }

    func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    /// A small all-caps caption above a value, the way macOS summaries read.
    func caption(_ text: String) -> NSTextField {
        let field = label(text, bold: false, size: 10)
        field.textColor = .tertiaryLabelColor
        field.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        return field
    }

    /// One “caption + value” column for the summary strip.
    func stat(_ captionText: String, _ value: NSTextField) -> NSStackView {
        value.font = NSFont.systemFont(ofSize: 12)
        value.textColor = .labelColor
        value.maximumNumberOfLines = 2
        value.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [caption(captionText), value])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    func buildWindow() {
        let text = strings
        let stored = UserDefaults.standard.string(forKey: languageKey) ?? "auto"

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 456),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = text.windowTitle
        window.center()
        // Closing the window hides it. The menu bar item is the app's real
        // home, so a closed window must not tear anything down.
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false

        let content = NSView()
        window.contentView = content

        statusLabel = label(text.connecting, bold: true, size: 17)
        detailLabel = label("")
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.font = NSFont.systemFont(ofSize: 12)
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byWordWrapping

        permissionLabel = label("")
        permissionLabel.textColor = .systemOrange
        permissionLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        permissionLabel.isHidden = true

        scheduleValue = label("—")
        capturedValue = label("—")
        actionValue = label("—")

        // A clock-time picker instead of a text field: the hours and minutes
        // segments can only hold valid values, so there is nothing to parse and
        // nothing to reject. `hourMinute` hides the date and the AM/PM column,
        // which keeps it a 24-hour `22:00` control like the config file.
        offPicker = timePicker("22:00", &offFieldRow)
        onPicker = timePicker("07:00", &onFieldRow)

        modePopup = NSPopUpButton()
        modePopup.addItems(withTitles: [text.modeCaptured, text.modeFixed])
        modePopup.target = self
        modePopup.action = #selector(modeChanged)

        // A colour well is a tiny square by nature; give it real size so it is
        // obvious it can be clicked.
        colorWell = NSColorWell()
        colorWell.color = nsColor(hex: "3366ff")
        colorWell.widthAnchor.constraint(equalToConstant: 92).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 28).isActive = true
        // Fire once when the picker settles, not on every drag step.
        colorWell.isContinuous = false
        colorWell.target = self
        colorWell.action = #selector(colourChanged)

        languagePopup = NSPopUpButton()
        languagePopup.addItems(withTitles: [
            text.languageSystem,
            "English",
            "简体中文",
        ])
        switch stored {
        case "en": languagePopup.selectItem(at: 1)
        case "zh-Hans": languagePopup.selectItem(at: 2)
        default: languagePopup.selectItem(at: 0)
        }
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)

        // Three states, not two buttons: "Schedule" follows the times below,
        // while On/Off hold until one of the others is chosen. A segmented
        // control shows which of those is in force instead of inviting a click.
        lightStateControl = NSSegmentedControl(
            labels: [text.stateSchedule, text.stateOn, text.stateOff],
            trackingMode: .selectOne,
            target: self,
            action: #selector(lightStateChanged)
        )
        lightStateControl.segmentStyle = .rounded
        lightStateControl.selectedSegment = 0
        lightStateControl.widthAnchor.constraint(equalToConstant: 204).isActive = true

        let colorButton = button(text.applyNow, action: #selector(applyColor))

        // Group the colour well with its action so it reads as one control.
        let colorRow = NSStackView(views: [colorWell, colorButton])
        colorRow.orientation = .horizontal
        colorRow.alignment = .centerY
        colorRow.spacing = 10

        func row(_ title: String, _ control: NSView) -> NSStackView {
            let name = label(title)
            name.alignment = .right
            name.widthAnchor.constraint(equalToConstant: 140).isActive = true
            let stack = NSStackView(views: [name, control])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 10
            return stack
        }
        let settings = NSStackView(views: [
            row(text.rowLightState, lightStateControl),
            row(text.rowOff, offFieldRow),
            row(text.rowOn, onFieldRow),
            row(text.rowMode, modePopup),
            row(text.rowColor, colorRow),
            row(text.rowLanguage, languagePopup),
        ])
        settings.orientation = .vertical
        settings.alignment = .leading
        settings.spacing = 10

        // Autosave confirmation: a quiet, transient line rather than a button.
        savedLabel = label("")
        savedLabel.textColor = .secondaryLabelColor
        savedLabel.font = NSFont.systemFont(ofSize: 11)
        savedLabel.isHidden = true

        // Summary strip: three equal columns, so the header reads as a card of
        // facts instead of a paragraph.
        let stats = NSStackView(views: [
            stat(text.captionSchedule, scheduleValue),
            stat(text.captionCaptured, capturedValue),
            stat(text.captionAction, actionValue),
        ])
        stats.orientation = .horizontal
        stats.distribution = .fillEqually
        stats.alignment = .top
        stats.spacing = 12

        // A plain layer-backed view instead of NSBox: NSBox lays out its
        // content view with old-style autoresizing, which broke the card.
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.5).cgColor
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor

        let cardStack = NSStackView(views: [
            statusLabel,
            detailLabel,
            permissionLabel,
            separator(),
            stats,
        ])
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 7
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)
        NSLayoutConstraint.activate([
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])
        stats.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true
        detailLabel.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true
        permissionLabel.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true
        statusLabel.widthAnchor.constraint(lessThanOrEqualTo: cardStack.widthAnchor).isActive = true

        let footer = NSStackView(views: [
            button(text.openPrivacy, action: #selector(openPrivacy)),
            button(text.restartAgent, action: #selector(restartAgent)),
        ])
        footer.orientation = .horizontal
        footer.spacing = 8

        for view in [card, settings, savedLabel!, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            card.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),

            settings.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 4),
            settings.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 18),

            savedLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            savedLabel.topAnchor.constraint(equalTo: settings.bottomAnchor, constant: 10),

            footer.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            footer.topAnchor.constraint(equalTo: savedLabel.bottomAnchor, constant: 12),
            footer.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
        ])

        // Placing the window on screen is all `buildWindow` does; whether the
        // app then takes focus is up to the caller (see `showWindow`).
        window.orderFront(nil)
    }

    // Closing the window hides it instead of dismantling the app.
    // Nothing to tear down here: the refresh timer keeps the menu bar item
    // honest while the window is closed.

    /// Rebuild the window in the newly selected language, keeping its frame.
    func rebuildWindow() {
        let frame = window.frame
        refreshTimer?.invalidate()
        window.close()
        // The language changed, so the menu bar item's menu has to follow too.
        NSStatusBar.system.removeStatusItem(statusItem)
        stateItems.removeAll()
        buildStatusItem()
        buildWindow()
        window.setFrame(frame, display: true)
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc func languageChanged() {
        switch languagePopup.indexOfSelectedItem {
        case 1: UserDefaults.standard.set("en", forKey: languageKey)
        case 2: UserDefaults.standard.set("zh-Hans", forKey: languageKey)
        default: UserDefaults.standard.set("auto", forKey: languageKey)
        }
        rebuildWindow()
    }

    func locale() -> Locale {
        Locale(identifier: strings.code == "zh-Hans" ? "zh_Hans_CN" : "en_US")
    }
}
