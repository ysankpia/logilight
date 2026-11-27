// The window's palette: an ink neutral ramp with one amber accent taken from
// the mouse's own LED. Dynamic colors, so the window follows the system
// appearance instead of pinning a theme.

import Cocoa

enum Palette {
    static let background = dynamic(dark: 0x0B0D14, light: 0xF5F7FA)
    static let titlebar = dynamic(dark: 0x0E1118, light: 0xEEF1F6)
    static let card = dynamic(dark: 0x11141C, light: 0xFFFFFF)
    static let raised = dynamic(dark: 0x1A1E28, light: 0xECEFF4)
    static let raisedStrong = dynamic(dark: 0x232733, light: 0xE3E8EF)
    static let text = dynamic(dark: 0xEEF0F5, light: 0x111827)
    static let secondary = dynamic(dark: 0xA3A9B8, light: 0x4B5565)
    static let muted = dynamic(dark: 0x7A8296, light: 0x6B7487)
    static let accent = dynamic(dark: 0xF2B544, light: 0xC98A12)
    static let dotOff = dynamic(dark: 0x4A5162, light: 0xAEB6C4)

    /// The 8% text tint the whole window uses for borders.
    static let hairline = NSColor(name: nil) { _ in
        (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.08)
    }

    static func dynamic(dark: UInt32, light: UInt32) -> NSColor {
        NSColor(name: nil) { _ in
            rgb(isDark ? dark : light)
        }
    }

    /// Ask the app, not the drawing appearance: a titlebar draws in
    /// `.vibrantDark`, which `bestMatch(from: [.aqua, .darkAqua])` answers with
    /// `.aqua`, so asking the passed appearance turned the dark titlebar light.
    private static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
