## What this changes

<!-- One or two sentences. Link the issue it closes, if any: Closes #123 -->

## How it was verified

<!--
Say what you actually ran or observed. "Tests pass" is not enough for
hardware changes: name the mouse model and what the lighting did.
-->

- [ ] `cargo fmt --all --check`
- [ ] `cargo clippy --all-targets -- -D warnings`
- [ ] `cargo test --all-targets`
- [ ] `xcrun swiftc -typecheck gui/LogiLight.swift` (if the window changed)
- [ ] Checked on real hardware: <!-- mouse model, what changed on the LEDs -->

## Checklist

- [ ] `CHANGELOG.md` has an entry under `[Unreleased]` (user-visible changes only)
- [ ] Docs updated if behaviour, config keys, or commands changed
- [ ] No secrets, tokens, or personal paths in the diff
- [ ] HID writes still happen only in the agent, never in the settings window
