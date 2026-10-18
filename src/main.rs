//! `logilight` — scheduled lighting control for Logitech HID++ mice on macOS.
//!
//! The tool talks to the mouse over Logitech's HID++ protocol using the same
//! device layer as OpenLogi (`openlogi-hid`), so it can drive the `0x8070`
//! `ColorLedEffects` engine (and the `0x8071` / `0x808x` fallbacks) without
//! Logi Options+ or a running OpenLogi agent.

mod config;
mod control;
mod daemon;
mod device;
mod launchd;
mod schedule;
mod state;
mod util;

use std::path::PathBuf;

use anyhow::Result;
use clap::{Parser, Subcommand};

use crate::config::Config;
use crate::util::now_local;

/// Scheduled lighting control for Logitech mice.
#[derive(Debug, Parser)]
#[command(name = "logilight", version, about)]
struct Cli {
    /// Config file to use. Defaults to `~/Library/Application Support/logilight/config.toml`.
    #[arg(long, global = true, env = "LOGILIGHT_CONFIG")]
    config: Option<PathBuf>,

    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Run the scheduler in the foreground.
    Daemon(daemon::DaemonArgs),
    /// Turn every selected device's lighting off now.
    Off,
    /// Restore lighting now (the colour captured before the last "off").
    On,
    /// Apply a solid colour now (`RRGGBB`, no `#`).
    Color {
        /// Colour as six hex digits.
        color: String,
    },
    /// Hand lighting back to the schedule and apply the phase it wants now.
    Auto,
    /// Show the schedule, devices, and last applied state.
    Status,
    /// Print the resolved config path and its contents.
    Config,
    /// Check Input Monitoring access and enumerate lighting devices.
    Doctor,
    /// Install the per-user launchd agent and start it.
    Install,
    /// Stop and remove the per-user launchd agent.
    Uninstall {
        /// Also delete the config, state, and logs.
        #[arg(long)]
        purge: bool,
    },
    /// Raise the macOS Input Monitoring prompt for this binary.
    RequestPermission,
    /// Print `granted` or `denied` for this binary (used by `install`).
    PermissionStatus,
}

fn main() -> Result<()> {
    // Restore the default SIGPIPE behaviour so `logilight status | head` exits
    // quietly instead of panicking on a closed pipe.
    #[cfg(unix)]
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }
    let cli = Cli::parse();
    let config_path = cli
        .config
        .clone()
        .unwrap_or_else(config::default_config_path);
    let command = cli.command.unwrap_or(Command::Status);
    let config = Config::load_or_default(&config_path)?;

    match command {
        Command::Daemon(args) => daemon::run(config, config_path, args),
        Command::Off => {
            let runtime = util::runtime()?;
            runtime.block_on(async {
                let mut state = state::State::load(&config_path);
                let applied = device::apply_off(&config, &mut state).await?;
                state.record("off", "manual", &applied)?;
                // Same rule as the settings window: the choice holds until the
                // schedule would have changed the lights anyway.
                state.set_manual("off", schedule::manual_hold(&config.schedule));
                state.save(&config_path)?;
                println!("lighting off — {} device(s) updated", applied.len());
                Ok(())
            })
        }
        Command::On => {
            let runtime = util::runtime()?;
            runtime.block_on(async {
                let mut state = state::State::load(&config_path);
                let applied = device::apply_on_color(&config, &mut state).await?;
                state.record("on", "manual", &applied)?;
                state.set_manual("on", schedule::manual_hold(&config.schedule));
                state.save(&config_path)?;
                println!("lighting restored — {} device(s) updated", applied.len());
                Ok(())
            })
        }
        Command::Color { color } => {
            let rgb = util::parse_hex_color(&color)?;
            let runtime = util::runtime()?;
            runtime.block_on(async {
                let applied = device::apply_rgb(&config, rgb).await?;
                let mut state = state::State::load(&config_path);
                // A colour chosen by hand is the colour to restore at dawn:
                // recording it here keeps the scheduler from resurrecting a
                // stale capture after the next lights-out.
                if rgb != config::OFF_COLOR {
                    device::remember_colors(&mut state, &applied);
                }
                let phase = if rgb == config::OFF_COLOR { "off" } else { "on" };
                state.record(phase, "manual", &applied)?;
                state.set_manual(phase, schedule::manual_hold(&config.schedule));
                state.save(&config_path)?;
                println!(
                    "applied #{} — {} device(s) updated",
                    util::format_hex_color(rgb),
                    applied.len()
                );
                Ok(())
            })
        }
        Command::Auto => {
            let runtime = util::runtime()?;
            runtime.block_on(async {
                let mut state = state::State::load(&config_path);
                state.clear_manual();
                let phase = schedule::phase_at(&config.schedule, util::now_local());
                let applied = device::apply_phase(&config, &mut state, phase).await?;
                let name = match phase {
                    schedule::Phase::Off => "off",
                    schedule::Phase::On => "on",
                };
                state.record(name, "scheduled", &applied)?;
                state.save(&config_path)?;
                println!(
                    "following the schedule — {name}, {} device(s) updated",
                    applied.len()
                );
                Ok(())
            })
        }
        Command::Status => {
            let runtime = util::runtime()?;
            runtime.block_on(device::print_status(&config, &config_path))
        }
        Command::Config => {
            println!("# {}", config_path.display());
            print!("{}", config.to_toml()?);
            Ok(())
        }
        Command::Doctor => {
            let runtime = util::runtime()?;
            runtime.block_on(doctor(&config, &config_path))
        }
        Command::Install => launchd::install(&config, &config_path),
        Command::Uninstall { purge } => launchd::uninstall(purge),
        Command::RequestPermission => launchd::request_permission(),
        Command::PermissionStatus => launchd::permission_status(),
    }
}

async fn doctor(config: &Config, config_path: &std::path::Path) -> Result<()> {
    println!("config: {}", config_path.display());
    println!("time:   {}", now_local().format("%Y-%m-%d %H:%M:%S %Z"));
    let granted = openlogi_hid::permissions::has_access();
    println!(
        "input monitoring: {}",
        if granted { "granted" } else { "NOT granted" }
    );
    if !granted {
        println!(
            "  grant it in System Settings → Privacy & Security → Input Monitoring,\n  \
             then restart the agent: launchctl kickstart -k gui/$(id -u)/{}",
            launchd::LABEL
        );
    }

    let devices = device::lighting_devices(config, true).await?;
    if devices.is_empty() {
        println!("devices: none found (is the mouse connected and awake?)");
    } else {
        println!("devices:");
        for found in devices {
            let color = match device::read_color(&found.route).await {
                Ok(Some(rgb)) => format!("#{}", util::format_hex_color(rgb)),
                Ok(None) => "unreadable".to_string(),
                Err(error) => format!("error: {error:#}"),
            };
            println!(
                "  {} [{}] kind={} lighting=yes current={color}",
                found.name, found.route, found.kind
            );
        }
    }

    let schedule = &config.schedule;
    println!(
        "schedule: {} (off {} → on {})",
        if schedule.enabled { "enabled" } else { "disabled" },
        schedule.off,
        schedule.on
    );
    Ok(())
}
