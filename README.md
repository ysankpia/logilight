# LogiLight

[![CI](https://github.com/ysankpia/logilight/actions/workflows/ci.yml/badge.svg)](https://github.com/ysankpia/logilight/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/ysankpia/logilight?sort=semver)](https://github.com/ysankpia/logilight/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A tiny macOS daemon that turns a Logitech mouse's RGB lighting **off at night and
back on in the morning**, without Logi Options+ or G HUB.

Default schedule: **off at 22:00, restore at 07:00**, every day.

Built on the same HID++ device layer as [OpenLogi](https://github.com/AprilNEA/OpenLogi)
(`openlogi-hid`, pinned to `ad3802aa` / v0.8.14).
Tested end-to-end on a wired **G502 HERO** (`046d:c08b`), which exposes HID++
`0x8070 ColorLedEffects`.

## What works

- Sets a solid colour through HID++ `0x8070`, with the `0x8071` / `0x808x`
  fallbacks OpenLogi uses for other devices.
- Captures the colour that was live when the lights went out and restores that
  exact colour in the morning (`restore.mode = "captured"`).
- Runs as a per-user `launchd` agent, starts at login, survives sleep/wake and
  device reconnects.
- Re-applies the night colour if the mouse forgets it (the write is volatile
  RAM, so a power cycle or firmware replay can undo it).
- Hot-reloads nothing: edit the config and restart the agent (one command).

## Install

Requirements: macOS 13+, Rust stable (1.98 or newer), and the mouse connected.
The OpenLogi crates are pulled from GitHub at a pinned revision, so there is
nothing else to clone.

```sh
git clone https://github.com/ysankpia/logilight.git
cd logilight
cargo build --release
./target/release/logilight install     # agent (background, invisible)
./scripts/build-gui.sh                 # settings app in /Applications
```

Building the settings app needs only the **Command Line Tools**, not Xcode
(`xcrun swiftc` is enough). `xcode-select -p` should print
`/Library/Developer/CommandLineTools`.

`install` does four things:

1. Creates `~/Library/Application Support/logilight/config.toml` if missing.
2. Installs a minimal `LogiLight.app` agent bundle under the same directory and
   signs it with a stable local self-signed certificate.
3. Registers `~/Library/LaunchAgents/com.luhui.logilight.plist` and starts it.
4. Asks for **Input Monitoring** the first time.

Reinstalling an unchanged build does nothing at all (under 0.2 s, no signing).
Rebuilding re-signs the app, but with the same certificate, so the existing
grant keeps working.

### The settings app

`scripts/build-gui.sh` compiles `gui/LogiLight.swift`, draws the icon, signs the
bundle, and installs **`/Applications/LogiLight.app`** — a normal app with a
Dock/Launchpad icon and a window. It is a thin front end: the daemon keeps the
HID connection (and the Input Monitoring grant), and the window talks to it over
`~/Library/Application Support/logilight/control.sock`. That is why the settings
window never triggers a TCC prompt of its own.

From the window you can:

- read the status card: current state, next change, schedule, night colour,
  and the last action;
- choose **Schedule / On / Off** for the lights. _Schedule_ follows the times
  below. _On_ and _Off_ hold your choice by hand until the next scheduled
  change, then the schedule takes over again. Nothing is written to the config
  when you use these, so the nightly routine keeps running;
- set the off and on times — they save as soon as you leave the field, there is
  no Save button;
- choose “restore the colour it had” or a fixed morning colour;
- pick a colour with the colour well; it is stored and applied immediately, or
  reuse **Apply colour now** to push the current well value again;
- switch the interface between **English and Simplified Chinese** — it follows
  the system language until you pick one, and the choice is remembered;
- open Input Monitoring settings, or restart the agent.

Everything except the light switch itself autosaves: times, morning colour,
colour well and language write through the daemon the moment they change, and a
small “Saved” note confirms it.

The agent bundle stays hidden on purpose: it is a background service. The
visible app is the one in `/Applications`.

### The one permission macOS requires

Opening a HID device from a background process needs
**System Settings → Privacy & Security → Input Monitoring**. The terminal you
build from already has that permission for its own child processes; a `launchd`
agent is a different process identity and needs its own grant.

`install` opens `LogiLight.app` so macOS raises the consent prompt. Turn on
“LogiLight” in the Input Monitoring list. The grant is tied to the certificate,
not to the binary hash, so **rebuilding and reinstalling keeps the grant**.

> Why a self-signed certificate instead of ad-hoc signing? TCC stores a
> designated requirement. Ad-hoc signing produces `cdhash H"…"`, which changes
> on every rebuild and silently invalidates the grant. A certificate-based
> requirement (`identifier "com.luhui.logilight" and certificate root = H"…"`)
> survives rebuilds.

The certificate and its private key live in your **login keychain**, which is
already unlocked and whose password you know. The first time `codesign` uses it,
macOS may show “codesign wants to sign using key …” — choose **Always Allow**
once and it never asks again. That is why the tool never creates a separate
keychain: a separate keychain would prompt for its own password, which is not
the password anyone would think to type.

If a rebuild ever loses the grant, reset the stale TCC row and approve once:

```sh
tccutil reset ListenEvent com.luhui.logilight
./target/release/logilight install
```

## Usage

```sh
logilight status              # schedule, phase, next change, devices, live colour
logilight off                 # turn lighting off now (captures the colour)
logilight on                  # restore the captured colour now
logilight color 3366ff        # apply a solid colour now
logilight auto                # drop a manual choice, follow the schedule again
logilight doctor              # permission + device inventory
logilight daemon --once       # evaluate the schedule once and exit
```

`off`, `on` and `color` take a manual hold that lasts until the next scheduled
change, exactly like the window's switch, so a hand-triggered test never leaves
the nightly routine disabled.

Run these with the installed binary if it is not on `PATH`:

```sh
"$HOME/Library/Application Support/logilight/LogiLight.app/Contents/MacOS/logilight" status
```

### Changing the schedule

Edit `~/Library/Application Support/logilight/config.toml`:

```toml
verbose = true

[devices]
names = []                 # case-insensitive substrings; empty = all lighting devices
product_ids = []           # e.g. [49291] for 0xc08b

[schedule]
enabled = true
off = "22:00"              # local wall clock, HH:MM
on = "07:00"               # may be earlier than off (crosses midnight)
tick_seconds = 30
reapply_on_arrival = true
scan_seconds = 20

[restore]
mode = "captured"          # or "fixed"
color = "ffffff"           # used when mode = "fixed"
fallback = "ffffff"        # used when no colour was captured
```

Then restart the agent:

```sh
launchctl kickstart -k gui/$(id -u)/com.luhui.logilight
```

`off` and `on` may be any `HH:MM`; a window that crosses midnight is normal.
`off == on` means “off all day”.

### Logs

```sh
tail -f "$HOME/Library/Application Support/logilight/log/logilight.log"
```

## How it works

```
launchd ──> LogiLight.app/Contents/MacOS/logilight daemon
                              │
                              ├─ every tick: read local clock, decide On/Off
                              ├─ on transition: enumerate → read live colour → write #000000
                              └─ at the morning edge: write the captured colour back
```

- Discovery and routing come from `openlogi-hid` (`enumerate`,
  `DeviceRoute::for_slot`).
- Writes go through `openlogi_hid::set_keyboard_color`, which drives `0x8070
ColorLedEffects` with volatile persistence and falls back to `0x8071`,
  `0x8081`, `0x8080`.
- Reading the live colour opens the same channel and calls `0x8070`'s
  `getCurrentColor`. If the device cannot report it, the configured
  `restore.fallback` is used.

### Manual override

A manual _On_ or _Off_ is stored in `state.json` as `manual` plus `manual_until`
(the next scheduled boundary). While it holds, the daemon keeps that phase
instead of the clock, which is what stops the next tick from undoing your click.
When the boundary arrives the override is cleared and the schedule resumes, so
choosing _Off_ at noon cannot silently cancel the 22:00 lights-out. Choosing
_Schedule_ in the window (or `logilight auto`) clears it immediately.

## Uninstall

```sh
./target/release/logilight uninstall          # stop + remove agent and app
./target/release/logilight uninstall --purge  # also delete config, state, logs
```

Remove “LogiLight” from Input Monitoring afterwards if you like.

## Troubleshooting

**Nothing happens at 22:00.** Check Input Monitoring is on for “LogiLight”, then
`launchctl kickstart -k gui/$(id -u)/com.luhui.logilight`. `logilight doctor`
shows `input monitoring: granted|NOT granted`.

**“Failed to match existing code requirement” in Console.** A stale TCC row from
an ad-hoc-signed build. Run `tccutil reset ListenEvent com.luhui.logilight`, then
`logilight install` and approve once.

**The light comes back at night.** The colour write is volatile. The daemon
re-applies on device arrival and drift every `scan_seconds`; a very short
`scan_seconds` catches firmware replays faster.

**It fights OpenLogi / Logi Options+.** Both programs open the same HID device.
Quit the other one, or keep LogiLight as the only thing driving lighting.

## Notes / limitations

- The G502 HERO has a single RGB zone; the tool writes the same colour to every
  zone a device reports.
- Restoring replaces an animated effect with a solid colour. That is the
  documented behaviour of the captured mode; use `restore.mode = "fixed"` if you
  prefer a fixed daytime colour.
- Only the mouse(s) matching the filter are touched. Keyboards with HID++ RGB
  are also supported by the same write path, but were not the target here.

## Releasing

`main` is protected: direct pushes are rejected, and both CI jobs must pass on
the pull request.

1. Add user-visible changes to `## [Unreleased]` in `CHANGELOG.md` as you go.
2. Before tagging, rename the section to the new version and a date, then add a
   fresh `## [Unreleased]` above it. Also bump `version` in `Cargo.toml` and
   `CFBundleShortVersionString` in `scripts/build-gui.sh`.
3. Update the compare links at the bottom of `CHANGELOG.md`.
4. Tag and release:

   ```sh
   git tag -a v0.2.0 -m "v0.2.0"
   git push origin v0.2.0
   gh release create v0.2.0 --title "v0.2.0" --notes-file notes.md
   ```

   The release body is the changelog section for that version, not the
   auto-generated list: `.github/release.yml` categories only help once pull
   requests carry the matching labels.

Versions follow [SemVer](https://semver.org/): `0.x` treats any behaviour change
as minor. There are no prebuilt binaries; each release is source-only.

## Research trail

The device layer is [OpenLogi](https://github.com/AprilNEA/OpenLogi) at commit
`ad3802a` (v0.8.14), pulled as a pinned git dependency. The relevant source:

- `crates/openlogi-device/src/write/lighting.rs` — `LightingMethod::Auto`,
  `set_color_effects`, zone/effect discovery.
- `crates/openlogi-hidpp/src/feature/color_led_effects.rs` — typed `0x8070`
  (`get_info`, `get_zone_info`, `get_zone_effect_info`, `set_zone_effect`,
  `get_current_color`).
- `crates/openlogi-hid/src/permissions.rs` — macOS Input Monitoring gate.
- `crates/openlogi-cli/src/cmd/diag/lighting.rs` — the CLI reference this tool
  started from.

## 中文速览

LogiLight 是一个 macOS 小工具：到点自动关闭罗技鼠标的灯光，早上再恢复。

- 安装：`cargo build --release`，然后 `./target/release/logilight install`
  装后台服务，`./scripts/build-gui.sh` 装图形界面到 `/Applications`。
- 图形界面默认跟随系统语言，可在窗口里的「语言」一栏切换 English / 简体中文，
  选择会被记住。
- 界面里「灯光状态」有三档：**定时**（按下面的时间走）、**打开**、**关闭**。
  手动选打开或关闭后，会一直保持到下一次定时切换，之后自动交还给定时。
- 时间、早晨颜色、色块、语言都是改完立即保存，没有「保存」按钮。
- 首次安装需要在「系统设置 → 隐私与安全性 → 输入监控」里勾选 LogiLight；
  这个授权跟证书绑定，之后更新版本不需要重新授权。
- 默认：22:00 关灯，07:00 恢复关灯前的颜色。也可以在界面或
  `~/Library/Application Support/logilight/config.toml` 里改。
- 命令行：`logilight status`、`logilight off`、`logilight on`、
  `logilight color 3366ff`、`logilight auto`、`logilight doctor`。

## Contributing

- [CONTRIBUTING.md](CONTRIBUTING.md) — setup, the checks CI runs, design rules,
  commit style.
- [SECURITY.md](SECURITY.md) — report vulnerabilities privately, and what counts
  as one here.
- [CHANGELOG.md](CHANGELOG.md) — what changed in each release.
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) — Contributor Covenant 2.1.

## License

MIT — see [LICENSE](LICENSE).
