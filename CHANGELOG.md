# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
