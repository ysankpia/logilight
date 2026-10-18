// LogiLight — settings window for the scheduled lighting agent.
//
// The daemon owns HID access (that is where the Input Monitoring grant lives),
// so this window never touches the device. It talks to the daemon over a Unix
// socket, which keeps the GUI free of TCC prompts.
//
// The interface ships in English and Simplified Chinese. It follows the system
// language by default and remembers a manual choice in UserDefaults.

import Cocoa

let socketPath = NSHomeDirectory() + "/Library/Application Support/logilight/control.sock"
let languageKey = "language"

/// One request/response round trip with the daemon.
func sendToAgent(_ command: String) -> [String: Any]? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { chars in
            for (index, byte) in pathBytes.enumerated() {
                chars[index] = CChar(bitPattern: byte)
            }
            chars[pathBytes.count] = 0
        }
    }

    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return nil }

    let request = Array((command + "\n").utf8)
    guard write(fd, request, request.count) == request.count else { return nil }

    var buffer = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(fd, &chunk, chunk.count)
        if count <= 0 {
            break
        }
        buffer.append(contentsOf: chunk[0 ..< count])
        if chunk[count - 1] == 0x0A {
            break
        }
    }
    guard let text = String(bytes: buffer, encoding: .utf8),
          let data = text.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func hexString(_ color: NSColor) -> String {
    let rgb = color.usingColorSpace(.deviceRGB) ?? NSColor.white
    let red = Int((rgb.redComponent * 255).rounded())
    let green = Int((rgb.greenComponent * 255).rounded())
    let blue = Int((rgb.blueComponent * 255).rounded())
    return String(format: "%02x%02x%02x", red, green, blue)
}

func nsColor(hex: String) -> NSColor {
    let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return .white }
    return NSColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: 1
    )
}

/// Every string the window shows, in one place per language.
struct Strings {
    let code: String
    let displayName: String

    let windowTitle: String
    let connecting: String
    let agentDown: String
    let agentDownHint: String
    let scheduleLine: String
    let nextChange: String
    let noPermission: String
    let captionSchedule: String
    let captionCaptured: String
    let captionAction: String

    let rowOff: String
    let rowOn: String
    let rowMode: String
    let rowColor: String
    let rowLanguage: String

    let modeCaptured: String
    let modeFixed: String
    let languageSystem: String

    let applyNow: String
    let openPrivacy: String
    let restartAgent: String
    let never: String

    let badTimes: String
    let notRunning: String
    let actionOff: String
    let actionOn: String
    let actionColour: String
    let actionSave: String
    let actionScheduled: String
    let actionManual: String
    let menuAbout: String
    let menuQuit: String

    /// Added for the state selector; kept last so the memberwise initialiser
    /// order stays easy to check against both language tables.
    /// Caption above the scheduled/on/off selector.
    let rowLightState: String
    /// Segments: follow the schedule, hold on, hold off.
    let stateSchedule: String
    let stateOff: String
    let stateOn: String
    /// Quiet autosave confirmation, shown in place of the old Save button.
    let autoSaved: String
    /// Headline: what the lights are doing right now.
    let statusOnLine: String
    let statusOffLine: String
    /// Detail line while a manual choice overrides the schedule.
    let manualHold: String

    static let english = Strings(
        code: "en",
        displayName: "English",
        windowTitle: "LogiLight",
        connecting: "Connecting to the agent…",
        agentDown: "Agent is not running",
        agentDownHint: "Use “Restart agent”, or run: launchctl kickstart -k gui/%d/com.luhui.logilight",
        scheduleLine: "Schedule: off %@ → on %@",
        nextChange: "Next change: %@",
        noPermission: "Input Monitoring is NOT granted — the agent cannot reach the mouse.",
        captionSchedule: "SCHEDULE",
        captionCaptured: "NIGHT COLOUR",
        captionAction: "LAST ACTION",
        rowOff: "Lights off at",
        rowOn: "Lights on at",
        rowMode: "Morning colour",
        rowColor: "Fixed colour",
        rowLanguage: "Language",
        modeCaptured: "Restore the colour it had",
        modeFixed: "Always use a fixed colour",
        languageSystem: "Follow system",
        applyNow: "Apply colour now",
        openPrivacy: "System permissions…",
        restartAgent: "Restart agent",
        never: "never",
        badTimes: "Times must look like 22:00 and 07:00.",
        notRunning: "The agent is not running, so %@ did nothing.",
        actionOff: "turning the lights off",
        actionOn: "restoring the lights",
        actionColour: "applying the colour",
        actionSave: "saving the settings",
        actionScheduled: "scheduled",
        actionManual: "manual",
        menuAbout: "About LogiLight",
        menuQuit: "Quit LogiLight",
        rowLightState: "Lighting",
        stateSchedule: "Schedule",
        stateOff: "Off",
        stateOn: "On",
        autoSaved: "Saved",
        statusOnLine: "Lights are on",
        statusOffLine: "Lights are off",
        manualHold: "set by hand — the schedule resumes at the next change"
    )

    static let chinese = Strings(
        code: "zh-Hans",
        displayName: "简体中文",
        windowTitle: "LogiLight 灯光控制",
        connecting: "正在连接后台服务…",
        agentDown: "后台服务未运行",
        agentDownHint: "点“重启服务”，或运行：launchctl kickstart -k gui/%d/com.luhui.logilight",
        scheduleLine: "定时：%1$@ 关灯 → %2$@ 开灯",
        nextChange: "下次切换：%@",
        noPermission: "尚未授予“输入监控”权限，后台服务无法访问鼠标。",
        captionSchedule: "定时",
        captionCaptured: "夜间颜色",
        captionAction: "上次操作",
        rowOff: "关灯时间",
        rowOn: "开灯时间",
        rowMode: "早晨颜色",
        rowColor: "固定颜色",
        rowLanguage: "语言",
        modeCaptured: "恢复关灯前的颜色",
        modeFixed: "始终使用固定颜色",
        languageSystem: "跟随系统",
        applyNow: "应用当前颜色",
        openPrivacy: "系统权限设置…",
        restartAgent: "重启服务",
        never: "从未",
        badTimes: "时间格式应为 22:00 和 07:00。",
        notRunning: "后台服务未运行，%1$@没有执行。",
        actionOff: "关灯",
        actionOn: "恢复灯光",
        actionColour: "应用颜色",
        actionSave: "保存设置",
        actionScheduled: "定时",
        actionManual: "手动",
        menuAbout: "关于 LogiLight",
        menuQuit: "退出 LogiLight",
        rowLightState: "灯光状态",
        stateSchedule: "定时",
        stateOff: "关闭",
        stateOn: "打开",
        autoSaved: "已保存",
        statusOnLine: "灯光已打开",
        statusOffLine: "灯光已关闭",
        manualHold: "手动设置中，下次定时切换时恢复自动"
    )

    static func resolve() -> Strings {
        let stored = UserDefaults.standard.string(forKey: languageKey) ?? "auto"
        if stored == "auto" {
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("zh") ? .chinese : .english
        }
        return stored.hasPrefix("zh") ? .chinese : .english
    }

    static func forStorage(_ value: String) -> Strings {
        value.hasPrefix("zh") ? .chinese : .english
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    private var window: NSWindow!
    private var statusLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var permissionLabel: NSTextField!
    private var scheduleValue: NSTextField!
    private var capturedValue: NSTextField!
    private var actionValue: NSTextField!
    private var offField: NSTextField!
    private var onField: NSTextField!
    private var modePopup: NSPopUpButton!
    private var colorWell: NSColorWell!
    private var languagePopup: NSPopUpButton!
    private var lightStateControl: NSSegmentedControl!
    private var savedLabel: NSTextField!
    private var refreshTimer: Timer?
    private var busy = false
    private var savedTimer: Timer?

    private var strings: Strings {
        Strings.resolve()
    }

    func applicationDidFinishLaunching(_: Notification) {
        buildMenu()
        buildWindow()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    private func buildMenu() {
        let text = strings
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: text.menuAbout,
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: text.menuQuit,
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    private func label(_ text: String, bold: Bool = false, size: CGFloat = 13) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        return field
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    /// A small all-caps caption above a value, the way macOS summaries read.
    private func caption(_ text: String) -> NSTextField {
        let field = label(text, bold: false, size: 10)
        field.textColor = .tertiaryLabelColor
        field.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        return field
    }

    /// One “caption + value” column for the summary strip.
    private func stat(_ captionText: String, _ value: NSTextField) -> NSStackView {
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

    private func buildWindow() {
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
        window.isReleasedWhenClosed = false

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

        offField = NSTextField(string: "22:00")
        onField = NSTextField(string: "07:00")
        for field in [offField!, onField!] {
            field.alignment = .center
            field.widthAnchor.constraint(equalToConstant: 84).isActive = true
            // No Save button: commit when editing ends (Return or click-away).
            // The delegate fires once; an action on the field would fire too
            // and write the same settings twice.
            field.delegate = self
        }

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
        // while On/Off hold until the next scheduled change. A segmented
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
            row(text.rowOff, offField),
            row(text.rowOn, onField),
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

        window.makeKeyAndOrderFront(nil)
    }

    /// Rebuild the window in the newly selected language, keeping its frame.
    private func rebuildWindow() {
        let frame = window.frame
        refreshTimer?.invalidate()
        window.close()
        buildMenu()
        buildWindow()
        window.setFrame(frame, display: true)
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc private func languageChanged() {
        switch languagePopup.indexOfSelectedItem {
        case 1: UserDefaults.standard.set("en", forKey: languageKey)
        case 2: UserDefaults.standard.set("zh-Hans", forKey: languageKey)
        default: UserDefaults.standard.set("auto", forKey: languageKey)
        }
        rebuildWindow()
    }

    private func locale() -> Locale {
        Locale(identifier: strings.code == "zh-Hans" ? "zh_Hans_CN" : "en_US")
    }

    private func refresh() {
        guard !busy else { return }
        let text = strings
        guard let status = sendToAgent("status") else {
            statusLabel.stringValue = text.agentDown
            detailLabel.stringValue = String(format: text.agentDownHint, Int(getuid()))
            permissionLabel.isHidden = true
            scheduleValue.stringValue = "—"
            capturedValue.stringValue = "—"
            actionValue.stringValue = "—"
            return
        }
        let phase = status["phase"] as? String ?? "on"
        let manual = status["manual"] as? Bool ?? false
        let device = status["device"] as? String ?? "—"
        let permission = status["permission"] as? Bool ?? false
        let off = status["off"] as? String ?? "?"
        let on = status["on"] as? String ?? "?"

        // The headline states the situation; the schedule lives in the stats
        // strip, so nothing here reads as a button to press.
        statusLabel.stringValue = phase == "off" ? text.statusOffLine : text.statusOnLine

        var detail = device
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
        capturedValue.stringValue = "#\(status["captured"] as? String ?? "—")"
        actionValue.stringValue = "\(actionName(status["action"] as? String ?? "")) · \(readable(status["updated"] as? String))"

        if offField.currentEditor() == nil {
            offField.stringValue = status["off"] as? String ?? offField.stringValue
        }
        if onField.currentEditor() == nil {
            onField.stringValue = status["on"] as? String ?? onField.stringValue
        }
        modePopup.selectItem(at: (status["mode"] as? String) == "fixed" ? 1 : 0)
        if !colorWell.isActive {
            colorWell.color = nsColor(hex: status["color"] as? String ?? "ffffff")
        }
    }

    private func actionName(_ raw: String) -> String {
        let text = strings
        switch raw {
        case "scheduled": return text.actionScheduled
        case "manual": return text.actionManual
        default: return raw.isEmpty ? "—" : raw
        }
    }

    private func readable(_ iso: String?) -> String {
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

    private func validTime(_ text: String) -> Bool {
        let parts = text.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0 ... 23).contains(hour), (0 ... 59).contains(minute) else { return false }
        return parts[0].count == 2 && parts[1].count == 2
    }

    private func run(_ command: String, describe: String) {
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

    private func present(_ message: String) {
        let alert = NSAlert()
        alert.messageText = strings.windowTitle
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func lightStateChanged() {
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

    // MARK: - Autosave

    /// The window saves itself; there is no Save button to forget to press.
    private func autoSave(_ command: String) {
        guard !busy else { return }
        busy = true
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

    private func flashSaved() {
        savedLabel.stringValue = strings.autoSaved
        savedLabel.isHidden = false
        savedTimer?.invalidate()
        savedTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            self?.savedLabel.isHidden = true
        }
    }

    /// Commit both times, keeping the field text when it is invalid so the
    /// user can see and fix what they typed.
    private func saveTimes() {
        let text = strings
        let off = offField.stringValue.trimmingCharacters(in: .whitespaces)
        let on = onField.stringValue.trimmingCharacters(in: .whitespaces)
        guard validTime(off), validTime(on) else {
            present(text.badTimes)
            return
        }
        // Nothing to write when the text still matches what the agent runs.
        guard let status = sendToAgent("status"),
              off != status["off"] as? String || on != status["on"] as? String else { return }
        autoSave("schedule \(off) \(on)")
    }

    private func saveRestore() {
        let mode = modePopup.indexOfSelectedItem == 1 ? "fixed" : "captured"
        autoSave("restore \(mode) \(hexString(colorWell.color))")
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === offField || field === onField else { return }
        saveTimes()
    }

    @objc private func modeChanged() {
        saveRestore()
    }

    /// Picking a colour stores it and applies it, the way the well previously
    /// needed a separate "apply" click.
    @objc private func colourChanged() {
        guard !busy else { return }
        let hex = hexString(colorWell.color)
        autoSave("restore \(modePopup.indexOfSelectedItem == 1 ? "fixed" : "captured") \(hex)")
        run("color \(hex)", describe: strings.actionColour)
    }

    @objc private func applyColor() {
        run("color \(hexString(colorWell.color))", describe: strings.actionColour)
    }

    @objc private func openPrivacy() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    @objc private func restartAgent() {
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

    private func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
