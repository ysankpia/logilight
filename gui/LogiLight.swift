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

    /// Menu bar item: reopen the window.
    let menuOpenWindow: String
    /// Menu bar items that mirror the three lighting states.
    let menuOff: String
    let menuOn: String
    let menuSchedule: String

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
        manualHold: "set by hand — the schedule resumes at the next change",
        menuOpenWindow: "Open LogiLight",
        menuOff: "Lights off now",
        menuOn: "Lights on now",
        menuSchedule: "Follow schedule"
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
        manualHold: "手动设置中，下次定时切换时恢复自动",
        menuOpenWindow: "打开 LogiLight",
        menuOff: "立即关灯",
        menuOn: "立即开灯",
        menuSchedule: "恢复按定时执行"
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSMenuDelegate {
    private var window: NSWindow!
    /// Menu bar presence: the app lives here, not in the Dock.
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    /// Menu bar items whose titles are rebuilt each time the menu opens.
    private var stateItems: [NSMenuItem] = []
    private var statusLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var permissionLabel: NSTextField!
    private var scheduleValue: NSTextField!
    private var capturedValue: NSTextField!
    private var actionValue: NSTextField!
    private var offPicker: NSDatePicker!
    private var onPicker: NSDatePicker!
    /// The picker plus its arrow columns, as one laid-out view.
    private var offFieldRow: NSView!
    private var onFieldRow: NSView!
    private var modePopup: NSPopUpButton!
    private var colorWell: NSColorWell!
    private var languagePopup: NSPopUpButton!
    private var lightStateControl: NSSegmentedControl!
    private var savedLabel: NSTextField!
    private var refreshTimer: Timer?
    private var busy = false
    private var savedTimer: Timer?
    /// Set while the time pickers should not be overwritten from the agent:
    /// the user is mid-edit, or a save is still in flight.
    private var editingTimes = false
    /// Which picker and segment each stepper drives, keyed by identity.
    private var steppers: [ObjectIdentifier: (NSDatePicker, Int)] = [:]

    private var strings: Strings {
        Strings.resolve()
    }

    func applicationDidFinishLaunching(_: Notification) {
        buildStatusItem()
        // An accessory app shows no menu bar, but the main menu still routes
        // key equivalents, so ⌘Q and ⌘W keep working while a window is focused.
        buildMenu()
        buildWindow()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Launching the app is a request to see the settings, so show the window
        // once. After that, closing it just hides it; the menu bar item stays.
        showWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    /// Closing the window hides it. Nothing is torn down: the refresh timer
    /// keeps the menu bar item honest while the window is closed.
    func windowWillClose(_: Notification) {}

    // MARK: - Menu bar

    /// A status item with the app icon, so the app is reachable after its
    /// window is closed. The Dock is deliberately not used: this is a small
    /// utility that belongs in the menu bar, like the other system agents.
    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = menuBarIcon()
            button.image?.isTemplate = true
            button.toolTip = Strings.resolve().windowTitle
        }

        statusMenu = NSMenu()
        statusMenu.delegate = self

        let open = NSMenuItem(
            title: Strings.resolve().menuOpenWindow,
            action: #selector(showWindow),
            keyEquivalent: ""
        )
        open.target = self
        statusMenu.addItem(open)
        statusMenu.addItem(.separator())

        let text = Strings.resolve()
        for (title, action) in [
            (text.menuOff, #selector(menuOff)),
            (text.menuOn, #selector(menuOn)),
            (text.menuSchedule, #selector(menuSchedule)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = .off
            statusMenu.addItem(item)
            stateItems.append(item)
        }

        statusMenu.addItem(.separator())
        let quit = NSMenuItem(
            title: Strings.resolve().menuQuit,
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        statusMenu.addItem(quit)

        statusItem.menu = statusMenu
    }

    /// The app icon, redrawn small enough for the menu bar and rendered as a
    /// template so it follows the light and dark menu bar automatically.
    private func menuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        let ring = NSBezierPath()
        ring.appendArc(
            withCenter: NSPoint(x: 9, y: 8),
            radius: 5.4,
            startAngle: 112,
            endAngle: 68,
            clockwise: false
        )
        ring.lineWidth = 2
        ring.lineCapStyle = .round
        NSColor.black.setStroke()
        ring.stroke()

        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: 9, y: 8.4))
        stem.line(to: NSPoint(x: 9, y: 15))
        stem.lineWidth = 2
        stem.lineCapStyle = .round
        stem.stroke()
        image.unlockFocus()
        return image
    }

    /// Refresh the tick marks right before the menu is shown, so the checkmark
    /// always matches what the agent is actually doing.
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        let text = strings
        for (index, item) in stateItems.enumerated() {
            item.title = [text.menuOff, text.menuOn, text.menuSchedule][index]
        }
        guard let status = sendToAgent("status") else {
            stateItems.forEach { $0.state = .off }
            return
        }
        let phase = status["phase"] as? String ?? "on"
        let manual = status["manual"] as? Bool ?? false
        stateItems[0].state = manual && phase == "off" ? .on : .off
        stateItems[1].state = manual && phase != "off" ? .on : .off
        stateItems[2].state = manual ? .off : .on
    }

    /// Bring the settings window back, creating nothing new if it still exists.
    /// `@objc` because the menu item targets it by selector.
    @objc func showWindow() {
        guard window != nil else {
            buildWindow()
            refresh()
            return
        }
        // An accessory app is not active when its menu is used, so a plain
        // orderFront would put the window behind whatever the user was doing.
        // Raise it first, then ask for activation.
        window.orderFrontRegardless()
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Double-clicking the app again in Finder reopens the window instead of
    /// starting a second copy that would fight for the same socket.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            showWindow()
        }
        return true
    }

    @objc private func menuOff() {
        run("off", describe: strings.actionOff)
    }

    @objc private func menuOn() {
        run("on", describe: strings.actionOn)
    }

    @objc private func menuSchedule() {
        run("auto", describe: strings.actionScheduled)
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
    private func rebuildWindow() {
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
        // The window can be hidden while the refresh timer keeps running, so
        // only touch the window's controls when there is a window to touch.
        guard window != nil, statusLabel != nil else { return }
        guard let status = sendToAgent("status") else {
            statusLabel.stringValue = text.agentDown
            detailLabel.stringValue = String(format: text.agentDownHint, Int(getuid()))
            permissionLabel.isHidden = true
            scheduleValue.stringValue = "—"
            capturedValue.stringValue = "—"
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

        updateStatusItem(phase: phase)
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

        // The agent is the source of truth, so the pickers follow it, except
        // while the user is mid-edit or a save is in flight. That window is
        // what keeps a 2-second refresh from fighting the stepper.
        if !editingTimes, !busy {
            offPicker.dateValue = date(fromClock: status["off"] as? String ?? "22:00")
            onPicker.dateValue = date(fromClock: status["on"] as? String ?? "07:00")
        }
        modePopup.selectItem(at: (status["mode"] as? String) == "fixed" ? 1 : 0)
        if !colorWell.isActive {
            colorWell.color = nsColor(hex: status["color"] as? String ?? "ffffff")
        }
    }

    /// Keep the menu bar item honest: a tooltip names the current state, and the
    /// icon dims when the lights are off, so the menu bar alone tells the story.
    private func updateStatusItem(phase: String?) {
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

    /// A 24-hour clock-time control: two spin segments, no date, no AM/PM.
    ///
    /// The stock `textFieldAndStepper` puts a single pair of arrows on the right
    /// edge, and with two segments those arrows act on the *last* one, so the
    /// arrow beside `22` would change the minutes. This builds one column of
    /// arrows per segment instead: up adds an hour or a minute, down removes
    /// one, and the order matches the text left to right.
    private func timePicker(_ clock: String, _ rowOut: inout NSView!) -> NSDatePicker {
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
    @objc private func stepperClicked(_ stepper: NSStepper) {
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
    private func date(fromClock clock: String) -> Date {
        var components = DateComponents(year: 2001, month: 1, day: 1)
        let parts = clock.split(separator: ":")
        components.hour = parts.count == 2 ? Int(parts[0]) : 22
        components.minute = parts.count == 2 ? Int(parts[1]) : 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: components) ?? Date()
    }

    /// `"22:00"`, zero padded, as the config file and the agent use it.
    private func clock(from date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    @objc private func timesChanged() {
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
    private func finishEditingTimes() {
        savedTimer?.invalidate()
        savedTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.editingTimes = false
            self.refresh()
        }
    }

    private func flashSaved() {
        savedLabel.stringValue = strings.autoSaved
        savedLabel.isHidden = false
        savedTimer?.invalidate()
        savedTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            self?.savedLabel.isHidden = true
        }
    }

    private func saveRestore() {
        let mode = modePopup.indexOfSelectedItem == 1 ? "fixed" : "captured"
        autoSave("restore \(mode) \(hexString(colorWell.color))")
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
// Accessory: no Dock tile, no app menu bar of its own, and no entry in Force
// Quit. The status item is the way in. `LSUIElement` in Info.plist says the
// same thing to the system before the process even starts.
application.setActivationPolicy(.accessory)
application.run()
