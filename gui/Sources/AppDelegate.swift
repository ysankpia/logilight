// The settings window's delegate: stored state and the app lifecycle.
// Everything else lives in extensions beside this file.

import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSMenuDelegate {
    var window: NSWindow!

    /// Menu bar presence: the app lives here, not in the Dock.
    var statusItem: NSStatusItem!

    var statusMenu: NSMenu!

    /// Menu bar items whose titles are rebuilt each time the menu opens.
    var stateItems: [NSMenuItem] = []

    var statusLabel: NSTextField!

    var detailLabel: NSTextField!

    var permissionLabel: NSTextField!

    /// The amber dot that carries the state.
    var statusDot: NSView!

    /// The 24 hour track under the headline.
    var nightBar: NightBarView!

    var lastLabel: NSTextField!

    var nowLabel: NSTextField!

    var offPicker: NSDatePicker!

    var onPicker: NSDatePicker!

    var languagePopup: NSPopUpButton!

    var lightStateControl: NSSegmentedControl!

    var refreshTimer: Timer?

    var busy = false

    /// Pause that lets a stepper click settle before the pickers are released.
    var savedTimer: Timer?

    /// Set while the time pickers should not be overwritten from the agent:
    /// the user is mid-edit, or a save is still in flight.
    var editingTimes = false

    var strings: Strings {
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
}
