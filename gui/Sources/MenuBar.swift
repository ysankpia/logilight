// The menu bar item: the app's real home while its window is closed.

import Cocoa

extension AppDelegate {
    // MARK: - Menu bar

    /// A status item with the app icon, so the app is reachable after its
    /// window is closed. The Dock is deliberately not used: this is a small
    /// utility that belongs in the menu bar, like the other system agents.
    func buildStatusItem() {
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
    func menuBarIcon() -> NSImage {
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

    @objc func menuOff() {
        run("off", describe: strings.actionOff)
    }

    @objc func menuOn() {
        run("on", describe: strings.actionOn)
    }

    @objc func menuSchedule() {
        run("auto", describe: strings.actionScheduled)
    }

    func buildMenu() {
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
}
