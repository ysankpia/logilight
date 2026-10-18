//! The foreground scheduler.
//!
//! One loop owns everything: it wakes at the next schedule boundary (or the
//! configured tick, whichever comes first), applies the phase the clock asks
//! for, and re-applies after sleep/wake or device arrival. The design keeps the
//! HID access in this one process, because macOS grants Input Monitoring per
//! code-signing identity and per process.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::Result;
use clap::Args;

use crate::config::{Config, OFF_COLOR, RestoreMode};
use crate::device::{self, FoundDevice};
use crate::schedule::{Phase, next_boundary, phase_at};
use crate::state::{AppliedDevice, State};
use crate::util::{Rgb, format_hex_color, now_local, parse_hex_color};

/// Arguments for `logilight daemon`.
#[derive(Debug, Args)]
pub struct DaemonArgs {
    /// Apply the phase the clock currently asks for and exit.
    #[arg(long)]
    pub once: bool,
}

/// Run the scheduler until terminated.
pub fn run(config: Config, config_path: PathBuf, args: DaemonArgs) -> Result<()> {
    let runtime = crate::util::runtime()?;
    runtime.block_on(async move {
        if args.once {
            return Scheduler::new(config, config_path).tick("startup").await;
        }
        log(
            &config,
            &format!(
                "started — off {} → on {}, tick {}s, scan {}s",
                config.schedule.off,
                config.schedule.on,
                config.schedule.tick_seconds,
                config.schedule.scan_seconds
            ),
        );
        if !openlogi_hid::permissions::has_access() {
            log(
                &config,
                "Input Monitoring is not granted to this process — device writes will fail",
            );
        }
        match device::lighting_devices(&config, false).await {
            Ok(devices) if devices.is_empty() => {
                log(&config, "no lighting-capable device found yet — will keep scanning");
            }
            Ok(devices) => log(
                &config,
                &format!(
                    "devices: {}",
                    devices
                        .iter()
                        .map(|device| format!("{} [{}]", device.name, device.route))
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
            ),
            Err(error) => log(&config, &format!("initial enumeration failed: {error:#}")),
        }
        let control_path = config_path.clone();
        let scheduler = Scheduler::new(config, config_path);
        let shared = std::sync::Arc::new(tokio::sync::Mutex::new(scheduler));
        let control = shared.clone();
        tokio::spawn(async move {
            crate::control::serve(control, control_path).await;
        });
        loop {
            let wait = {
                let mut scheduler = shared.lock().await;
                if let Err(error) = scheduler.tick("scheduled").await {
                    log(&scheduler.config, &format!("tick failed: {error:#}"));
                }
                wait_duration(&scheduler.config)
            };
            tokio::time::sleep(wait).await;
        }
    })
}

/// How long to sleep before the next check.
///
/// The next boundary is the real deadline; the tick bounds drift and also
/// recovers from a laptop sleeping through a boundary. Both are capped so a
/// long overnight sleep still re-evaluates soon after wake.
fn wait_duration(config: &Config) -> Duration {
    let tick = Duration::from_secs(config.schedule.tick_seconds);
    let Some(boundary) = next_boundary(&config.schedule, now_local()) else {
        return tick;
    };
    let until = (boundary - now_local()).to_std().unwrap_or(tick);
    // Wake a second early so a slightly fast clock never misses the edge, and
    // never sleep longer than the tick so wake-from-sleep is re-checked.
    let until = until.saturating_sub(Duration::from_secs(1));
    until.min(tick).max(Duration::from_secs(1))
}

/// Long-lived scheduler state that does not belong in the on-disk state file.
pub(crate) struct Scheduler {
    pub(crate) config: Config,
    config_path: PathBuf,
    /// Routes present at the previous scan, for arrival detection.
    known_routes: BTreeSet<String>,
    /// When colours were last compared against the wanted phase.
    last_reapply_check: Option<Instant>,
}

impl Scheduler {
    fn new(config: Config, config_path: PathBuf) -> Self {
        Self {
            config,
            config_path,
            known_routes: BTreeSet::new(),
            last_reapply_check: None,
        }
    }

    /// One evaluation: decide the phase, apply it when needed, and heal drift.
    async fn tick(&mut self, action: &str) -> Result<()> {
        let mut state = State::load(&self.config_path);
        let scheduled = phase_at(&self.config.schedule, now_local());
        // A manual on/off wins until the next boundary: otherwise the user
        // flips the lights by hand and the very next tick flips them back.
        let manual = state.active_manual().map(str::to_string);
        let expired = manual.is_none() && state.manual.is_some();
        if expired {
            state.clear_manual();
        }
        let phase = match manual.as_deref() {
            Some("off") => Phase::Off,
            Some("on") => Phase::On,
            _ => scheduled,
        };
        let devices = match device::lighting_devices(&self.config, false).await {
            Ok(devices) => devices,
            Err(error) => {
                log(&self.config, &format!("enumeration failed: {error:#}"));
                Vec::new()
            }
        };

        let routes: BTreeSet<String> = devices.iter().map(FoundDevice::key).collect();
        let arrived: Vec<String> = routes.difference(&self.known_routes).cloned().collect();
        self.known_routes = routes;

        if devices.is_empty() {
            return Ok(());
        }

        let wanted = match phase {
            Phase::Off => "off",
            Phase::On => "on",
        };
        let mut dirty = expired;

        if state.phase != wanted {
            let applied = self.apply_phase(phase, &mut state, action).await?;
            if !applied.is_empty() || action == "startup" {
                state.record(wanted, action, &applied)?;
                log(
                    &self.config,
                    &format!(
                        "{} — {} device(s): {}",
                        if phase == Phase::Off {
                            "lights out"
                        } else {
                            "lights on"
                        },
                        applied.len(),
                        describe(&applied)
                    ),
                );
            }
            dirty = true;
            self.last_reapply_check = Some(Instant::now());
        } else if !arrived.is_empty() || self.reapply_due() {
            let applied = self.heal(phase, &mut state).await?;
            if !applied.is_empty() {
                log(
                    &self.config,
                    &format!(
                        "re-applied {} on {} device(s): {}",
                        wanted,
                        applied.len(),
                        describe(&applied)
                    ),
                );
                state.record(wanted, if arrived.is_empty() { "drift" } else { "arrival" }, &applied)?;
                dirty = true;
            }
            self.last_reapply_check = Some(Instant::now());
        }

        if dirty {
            state.save(&self.config_path)?;
        }
        Ok(())
    }

    /// Whether the periodic drift check is due.
    fn reapply_due(&self) -> bool {
        if !self.config.schedule.reapply_on_arrival {
            return false;
        }
        let interval = Duration::from_secs(self.config.schedule.scan_seconds);
        self.last_reapply_check
            .is_none_or(|last| last.elapsed() >= interval)
    }

    /// Apply the phase to every selected device, capturing colours before an
    /// off write.
    async fn apply_phase(
        &self,
        phase: Phase,
        state: &mut State,
        _action: &str,
    ) -> Result<Vec<AppliedDevice>> {
        match phase {
            Phase::Off => device::apply_off(&self.config, state).await,
            Phase::On => device::apply_on_color(&self.config, state).await,
        }
    }

    /// Re-write the wanted colour only where the device shows something else.
    ///
    /// An unreadable device is skipped rather than written blindly: a device
    /// that answers HID++ but not the colour read is not necessarily wrong,
    /// and hammering it on every tick would be worse than a stale LED.
    async fn heal(&self, phase: Phase, state: &mut State) -> Result<Vec<AppliedDevice>> {
        let devices = device::lighting_devices(&self.config, false).await?;
        let mut applied = Vec::new();
        for device in &devices {
            let wanted = match phase {
                Phase::Off => OFF_COLOR,
                Phase::On => wanted_on_color(&self.config, state, device),
            };
            let differs = matches!(
                device::read_color(&device.route).await,
                Ok(Some(current)) if current != wanted
            );
            if !differs {
                continue;
            }
            let (r, g, b) = wanted.components();
            match openlogi_hid::set_keyboard_color(&device.route, r, g, b).await {
                Ok(()) => applied.push(AppliedDevice {
                    name: device.name.clone(),
                    route: device.route.to_string(),
                    color: format_hex_color(wanted),
                }),
                Err(error) => log(
                    &self.config,
                    &format!("re-apply failed on {}: {error}", device.name),
                ),
            }
        }
        Ok(applied)
    }
}

/// The colour the "on" phase should show for one device.
fn wanted_on_color(config: &Config, state: &State, device: &FoundDevice) -> Rgb {
    let fallback = parse_hex_color(&config.restore.fallback).unwrap_or(Rgb::new(255, 255, 255));
    match config.restore.mode {
        RestoreMode::Fixed => parse_hex_color(&config.restore.color).unwrap_or(fallback),
        RestoreMode::Captured => state
            .captured
            .get(&device.key())
            .and_then(|hex| parse_hex_color(hex).ok())
            .unwrap_or(fallback),
    }
}

fn describe(applied: &[AppliedDevice]) -> String {
    applied
        .iter()
        .map(|entry| format!("{} → #{}", entry.name, entry.color))
        .collect::<Vec<_>>()
        .join(", ")
}

/// Write a timestamped line when the config asks for it.
pub(crate) fn log(config: &Config, message: &str) {
    if config.verbose {
        println!("{} {message}", now_local().format("%Y-%m-%d %H:%M:%S"));
    }
}
