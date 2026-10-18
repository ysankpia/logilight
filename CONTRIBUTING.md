# Contributing to LogiLight

Thanks for taking a look. This is a small tool with one unusual property: it
changes hardware state. A change that "looks fine" but leaves the mouse dark at
noon is a bug, so the bar for evidence is higher than usual.

## Before you start

| Requirement        | Notes                                                         |
| ------------------ | ------------------------------------------------------------- |
| macOS 13 or newer  | The agent is macOS-only (launchd + IOKit).                    |
| Rust 1.98+         | `rust-version` in `Cargo.toml` is the source of truth.        |
| Command Line Tools | Enough to build the window; the full Xcode app is not needed. |

Check the toolchain:

```sh
xcode-select -p    # expect /Library/Developer/CommandLineTools
rustc --version    # expect 1.98 or newer
```

You do not need to clone OpenLogi: the HID layer is a pinned git dependency.

## Build and run locally

```sh
cargo build --release
./target/release/logilight install     # agent, background and invisible
./scripts/build-gui.sh                 # settings window in /Applications
```

`install` signs the agent bundle with a local self-signed certificate. The
certificate is created on first use and lives in your login keychain; see
[the signing note](README.md#the-one-permission-macos-requires) for why.

## Checks that must pass

Run exactly these before opening a pull request — CI runs the same commands:

```sh
cargo fmt --all --check
cargo clippy --all-targets -- -D warnings
cargo test --all-targets
xcrun swiftc -typecheck gui/LogiLight.swift   # if you touched the window
```

`cargo fmt` uses the edition pinned in `rustfmt.toml`. Formatting a single file
with a bare `rustfmt file.rs` picks up the same config, so the two paths agree.

## Hardware changes need hardware evidence

If your change affects a write, a read, or timing:

1. Name the device (model, wired/receiver, `vendor:product`).
2. State what the LEDs did before and after, not just that the command exited 0.
3. Include the relevant lines from
   `~/Library/Application Support/logilight/log/logilight.log`.

CI cannot verify this. Say plainly in the PR what you observed, and what you
could not test.

## Design rules

These keep the TCC story intact — please do not break them without discussing:

- **Only the agent touches HID.** The window talks to the agent over the Unix
  socket in `~/Library/Application Support/logilight/control.sock`. A new
  process that opens the device means a new Input Monitoring grant to lose.
- **One stable signing identity.** The bundle identifier and certificate are
  what TCC remembers. Renaming either silently revokes the user's grant.
- **No new network code.** The tool is offline by design.
- **Keep the daemon single-purpose.** Scheduling and colour writes belong in
  `src/daemon.rs` / `src/device.rs`; the window stays a client.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):
`type(scope): summary`, imperative mood, 72 characters or fewer.

Common types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `build`,
`ci`, `chore`. Examples from this history:

```text
fix: hold a manual on/off until the next scheduled boundary
build: pin rustfmt to edition 2024
```

## Changelog

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Add user-visible changes under `## [Unreleased]` in the right group (`Added`,
`Changed`, `Fixed`, `Removed`). Internal refactors, tests, and CI changes do not
need an entry.

## Pull requests

- One topic per pull request; keep unrelated formatting out of a fix.
- Fill in the template, including how you verified the change.
- CI must be green. Review comments are about behaviour and evidence, not taste.
- Squash-merge is the default; the PR title becomes the commit message, so make
  it a valid Conventional Commit.

## Reporting bugs and security issues

- Bugs: the issue form asks for the device details and logs needed to reproduce.
- Vulnerabilities: see [SECURITY.md](SECURITY.md). Never open a public issue for
  one.
