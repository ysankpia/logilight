# Security Policy

## Supported versions

| Version | Supported                  |
| ------- | -------------------------- |
| 0.1.x   | Yes (current release line) |

Older releases do not receive fixes; the tool is small enough that upgrading is
the fix.

## Reporting a vulnerability

Report privately through
[GitHub Security Advisories](https://github.com/ysankpia/logilight/security/advisories/new).
Please do not open a public issue.

Include: what you can control or observe, the steps, the version, and your macOS
version. A proof of concept helps.

You can expect an initial reply within about a week. If the report is valid, the
fix ships in a patch release and the advisory is published once it is available.

## Scope notes

This tool runs a per-user `launchd` agent that opens a HID device, so the
interesting surfaces are narrow:

- **Local privilege and TCC.** The agent needs Input Monitoring. Anything that
  makes a _different_ process ask for that grant, or that widens what the agent
  does with the HID channel beyond lighting, is in scope.
- **The control socket.** `~/Library/Application Support/logilight/control.sock`
  accepts commands from the same user and is created with mode `0600`. Another
  local user reaching it, or a command that escapes that account, is in scope.
- **Config parsing.** `config.toml` is user-controlled input. A crafted file
  causing a crash, an arbitrary file write, or command execution is in scope.
- **Supply chain.** The dependency pins in `Cargo.toml` matter. A malicious
  upstream revision is in scope.

Out of scope: the mouse lighting is volatile by design, so "the light came back
after a power cycle" is expected behaviour rather than a vulnerability. Physical
access to an unlocked machine, and self-inflicted `sudo` misuse, are also out of
scope.

## What this project does not do

- No network access at runtime.
- No credentials, tokens, or telemetry.
- No background update mechanism.
