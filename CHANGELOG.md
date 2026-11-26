# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Pointer DPI: `logilight dpi` reads the value in force plus the range the
  device lists, `logilight dpi 1600` writes one (snapped to the nearest value
  the device accepts, then read back), and the settings window shows a slider
  with the same range.
- Optional smooth wheel scrolling: one event tap in the daemon replays each
  notch in small steps. Off by default, needs Accessibility, installs no tap
  while it is off, re-enables itself when the system disables the tap, and
  switches itself off if it cannot post.
- `−` and `+` beside the DPI and smoothing sliders, stepping by the device's
  DPI step (50) and by 25 ms, so both land on a round number without dragging.
- `logilight smooth duration <ms>` sets the smoothing duration from the CLI.
- Menu bar item with the light state, _Off / On / Schedule_, _Open LogiLight_,
  and _Quit_. The icon dims while the lights are off and its tooltip names the
  current state.
- Clock pickers for the off and on times: an hour column and a minute column of
  arrows, seeded from the config and saved on every change.

### Changed

- A manual _On_ or _Off_ now holds until another state is chosen, instead of
  lapsing at the next scheduled boundary. Turning the lights off by hand keeps
  them off through the night and the next morning until _Schedule_ (or
  `logilight auto`) hands control back to the timetable.
- A colour write that HID++ drops is retried up to three times, half a second
  apart, and the log names every attempt. An idle device no longer leaves the
  lights in the previous phase until the next 30 s tick.
- A tick that could not reach the device is re-evaluated after 2 s instead of
  waiting for the next scheduled tick.
- `install` retries the `launchctl bootstrap` that follows `bootout`, which
  launchd could reject with `Bootstrap failed: 5` while the old job was still
  shutting down, leaving the agent stopped.
- The settings app is now a background agent: `LSUIElement` plus a `.accessory`
  activation policy, so it has no Dock tile, no ⌘-Tab entry and no row in the
  Force Quit window. Closing the window hides it, reopening comes from the menu
  bar or by launching the app again, and the app keeps following the schedule
  either way.
- Time entry no longer depends on parsing typed text: the pickers cannot hold an
  invalid time, and a 2-second refresh no longer overwrites the value being
  edited.

### Removed

- The “Times must look like 22:00 and 07:00” error path, which the pickers make
  unreachable.

## [0.1.0] - 2026-10-18

First public release. Verified end-to-end on a wired G502 HERO (`046d:c08b`).

### Added

- Scheduled lighting: lights out and colour restore at configurable local times,
  including windows that cross midnight and DST transitions.
- Captured-colour restore: the colour live before lights-out is written back in
  the morning, with a fixed-colour mode and a fallback when a device cannot
  report its current colour.
- Drift healing: the night colour is re-applied on device arrival and on a
  configurable interval, because the HID write is volatile.
- Manual **On / Off / Schedule** selector in the settings window. A manual choice
  holds until the next scheduled boundary, so it cannot silently disable the
  nightly routine.
- Settings window (English and Simplified Chinese, following the system
  language) that autosaves times, morning colour, colour well, and language.
- Unix-socket control channel, so the window never opens a HID device and never
  needs its own Input Monitoring grant.
- CLI: `status`, `off`, `on`, `color`, `auto`, `daemon`, `config`, `doctor`,
  `install`, `uninstall`, `request-permission`, `permission-status`.
- Stable self-signed signing identity in the login keychain, so rebuilding keeps
  the existing Input Monitoring grant. Unchanged builds skip copying and signing.
- `install` / `uninstall` for the per-user launchd agent and the app bundle.
- Control log lines name the process that sent each command, so an unexpected
  lighting change can be traced to a window click or a script.

### Notes

- macOS 13+ only. The daemon is the only process that touches HID.
- The mouse lighting is volatile: some devices forget the colour after a power
  cycle, which the drift check recovers.

[Unreleased]: https://github.com/ysankpia/logilight/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ysankpia/logilight/releases/tag/v0.1.0
