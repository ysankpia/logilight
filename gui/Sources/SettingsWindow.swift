// The settings window: one status card with the night bar, four rows, footer.

import Cocoa

extension AppDelegate {
    func label(
        _ text: String,
        size: CGFloat = 13,
        weight: NSFont.Weight = .regular,
        color: NSColor = Palette.text
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func hairline() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = Palette.hairline.cgColor
        view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return view
    }

    func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    /// One settings row: a right-aligned 96 pt label, then the control.
    func row(_ title: String, _ control: NSView) -> NSStackView {
        let name = label(title, color: Palette.secondary)
        name.alignment = .right
        name.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let stack = NSStackView(views: [name, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        return stack
    }

    func buildWindow() {
        let text = strings
        let stored = UserDefaults.standard.string(forKey: languageKey) ?? "auto"

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = text.windowTitle
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Palette.titlebar
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Palette.background.cgColor
        window.contentView = content

        // ---- status card: the one moment ----

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = Palette.card.cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Palette.hairline.cgColor

        statusDot = NSView()
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        statusLabel = label("—", size: 15, weight: .medium)
        let stateRow = NSStackView(views: [statusDot, statusLabel])
        stateRow.orientation = .horizontal
        stateRow.alignment = .centerY
        stateRow.spacing = 8

        detailLabel = label("", size: 13, color: Palette.secondary)
        permissionLabel = label(text.noPermission, size: 12, color: Palette.accent)
        permissionLabel.isHidden = true
        let detailStack = NSStackView(views: [detailLabel, permissionLabel])
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 4

        nightBar = NightBarView()

        lastLabel = label("", size: 12, color: Palette.muted)
        nowLabel = label("", size: 12, color: Palette.muted)
        lastLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        nowLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let lastRow = NSStackView(views: [lastLabel, nowLabel])
        lastRow.orientation = .horizontal
        lastRow.distribution = .equalSpacing
        lastRow.alignment = .centerY

        for view in [stateRow, detailStack, nightBar, lastRow] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(view)
        }
        NSLayoutConstraint.activate([
            stateRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stateRow.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -20),
            stateRow.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),

            detailStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 36),
            detailStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            detailStack.topAnchor.constraint(equalTo: stateRow.bottomAnchor, constant: 4),

            nightBar.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 36),
            nightBar.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            nightBar.topAnchor.constraint(equalTo: detailStack.bottomAnchor, constant: 16),
            nightBar.heightAnchor.constraint(equalToConstant: 32),

            lastRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 36),
            lastRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            lastRow.topAnchor.constraint(equalTo: nightBar.bottomAnchor, constant: 12),
            lastRow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
        ])

        // ---- settings ----

        // Three states, one control: the same primitive the schedule uses.
        lightStateControl = NSSegmentedControl(
            labels: [text.stateSchedule, text.stateOn, text.stateOff],
            trackingMode: .selectOne,
            target: self,
            action: #selector(lightStateChanged)
        )
        lightStateControl.segmentStyle = .rounded
        lightStateControl.selectedSegment = 0
        lightStateControl.widthAnchor.constraint(equalToConstant: 176).isActive = true

        offPicker = timePicker("22:00")
        onPicker = timePicker("07:00")

        languagePopup = NSPopUpButton()
        languagePopup.addItems(withTitles: [text.languageSystem, "English", "简体中文"])
        switch stored {
        case "en": languagePopup.selectItem(at: 1)
        case "zh-Hans": languagePopup.selectItem(at: 2)
        default: languagePopup.selectItem(at: 0)
        }
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        languagePopup.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let times = NSStackView(views: [
            row(text.rowOff, offPicker),
            row(text.rowOn, onPicker),
        ])
        times.orientation = .vertical
        times.alignment = .leading
        times.spacing = 12

        let settings = NSStackView(views: [
            row(text.rowLightState, lightStateControl),
            times,
            row(text.rowLanguage, languagePopup),
        ])
        settings.orientation = .vertical
        settings.alignment = .leading
        settings.spacing = 12
        settings.setCustomSpacing(20, after: times)

        let rule = hairline()
        let footer = NSStackView(views: [
            button(text.openPrivacy, action: #selector(openPrivacy)),
            button(text.restartAgent, action: #selector(restartAgent)),
        ])
        footer.orientation = .horizontal
        footer.spacing = 8

        for view in [card, settings, rule, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            card.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),

            settings.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            settings.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 20),

            rule.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            rule.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            rule.topAnchor.constraint(equalTo: settings.bottomAnchor, constant: 24),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            footer.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 16),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])

        let size = content.fittingSize
        window.setContentSize(NSSize(width: 520, height: size.height))
        window.center()
        window.orderFront(nil)
        // No control should open with a focus ring; nothing here is a form.
        window.makeFirstResponder(nil)
    }

    /// Rebuild the window in the newly selected language, keeping its frame.
    func rebuildWindow() {
        let frame = window.frame
        refreshTimer?.invalidate()
        window.close()
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
