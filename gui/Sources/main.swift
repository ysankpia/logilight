// LogiLight — settings window for the scheduled lighting agent.
//
// The daemon owns HID access (that is where the Input Monitoring grant
// lives), so this window never touches the device. It talks to the daemon
// over a Unix socket, which keeps the GUI free of TCC prompts.
//
// The interface ships in English and Simplified Chinese. It follows the
// system language by default and remembers a manual choice in UserDefaults.
//
// Entry point. Top-level code must live in main.swift once the GUI is
// compiled from several files.

import Cocoa

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Accessory: no Dock tile, no app menu bar of its own, and no entry in Force
// Quit. The status item is the way in. `LSUIElement` in Info.plist says the
// same thing to the system before the process even starts.
application.setActivationPolicy(.accessory)
application.run()
