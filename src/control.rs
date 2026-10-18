//! Local control channel for the GUI.
//!
//! The daemon is the only process with Input Monitoring, so it also answers
//! requests from the settings window over a Unix socket. The GUI therefore
//! never opens a HID device itself and never needs its own TCC grant.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result, bail};
use serde::Serialize;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::Mutex;

use crate::config::{Config, RestoreMode};
use crate::daemon::Scheduler;
use crate::device;
use crate::schedule::{next_boundary, parse_clock, phase_at};
use crate::state::State;
use crate::util::{format_hex_color, now_local, parse_hex_color};

/// Where the settings window connects.
#[must_use]
pub fn socket_path() -> PathBuf {
    crate::config::data_dir().join("control.sock")
}

/// Start serving control requests. Runs until the process exits.
pub async fn serve(scheduler: Arc<Mutex<Scheduler>>, config_path: PathBuf) {
    if let Err(error) = serve_inner(scheduler, config_path).await {
        eprintln!("control channel stopped: {error:#}");
    }
}

async fn serve_inner(scheduler: Arc<Mutex<Scheduler>>, config_path: PathBuf) -> Result<()> {
    let path = socket_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("create {}", parent.display()))?;
    }
    // A stale socket from a killed daemon would make bind fail.
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path)
        .with_context(|| format!("bind {}", path.display()))?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
        .with_context(|| format!("restrict {}", path.display()))?;

    loop {
        let (stream, _) = listener.accept().await.context("accept control client")?;
        if let Err(error) = handle(stream, &scheduler, &config_path).await {
            eprintln!("control request failed: {error:#}");
        }
    }
}

async fn handle(
    stream: UnixStream,
    scheduler: &Arc<Mutex<Scheduler>>,
    config_path: &Path,
) -> Result<()> {
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    // A client that connects and never speaks must not stall the channel.
    tokio::time::timeout(
        std::time::Duration::from_secs(5),
        reader.read_line(&mut line),
    )
    .await
    .context("control client timed out")??;
    let response = dispatch(line.trim(), scheduler, config_path).await;
    let mut stream = reader.into_inner();
    let text = match response {
        Ok(text) => text,
        Err(error) => serde_json::json!({ "ok": false, "error": format!("{error:#}") })
            .to_string(),
    };
    stream.write_all(text.as_bytes()).await?;
    stream.write_all(b"\n").await?;
    stream.flush().await?;
    Ok(())
}

async fn dispatch(
    line: &str,
    scheduler: &Arc<Mutex<Scheduler>>,
    config_path: &Path,
) -> Result<String> {
    let mut parts = line.split_whitespace();
    let command = parts.next().unwrap_or("");
    // Record the requests that change something: when the lights move
    // unexpectedly, the log has to answer "who asked for that". Status polls
    // every couple of seconds and would drown everything else.
    if !matches!(command, "" | "status") {
        let arguments: Vec<&str> = parts.clone().collect();
        crate::daemon::log(
            &scheduler.lock().await.config,
            &format!("control: {command} {}", arguments.join(" ")),
        );
    }
    match command {
        "status" => {
            let scheduler = scheduler.lock().await;
            Ok(serde_json::to_string(&status(&scheduler, config_path))?)
        }
        "off" => {
            let scheduler = scheduler.lock().await;
            let mut state = State::load(config_path);
            let applied = device::apply_off(&scheduler.config, &mut state).await?;
            device::remember_colors(&mut state, &applied);
            state.record("off", "manual", &applied)?;
            // Hold the choice until the schedule would act again, so the next
            // tick does not immediately turn the lights back on.
            state.set_manual("off", hold_until(&scheduler.config));
            state.save(config_path)?;
            Ok(applied_json(&applied))
        }
        "on" => {
            let scheduler = scheduler.lock().await;
            let mut state = State::load(config_path);
            let applied = device::apply_on_color(&scheduler.config, &mut state).await?;
            device::remember_colors(&mut state, &applied);
            state.record("on", "manual", &applied)?;
            state.set_manual("on", hold_until(&scheduler.config));
            state.save(config_path)?;
            Ok(applied_json(&applied))
        }
        "color" => {
            let hex = parts.next().context("color needs RRGGBB")?;
            let color = parse_hex_color(hex)?;
            let scheduler = scheduler.lock().await;
            let applied = device::apply_rgb(&scheduler.config, color).await?;
            let mut state = State::load(config_path);
            state.record("on", "manual", &applied)?;
            state.set_manual("on", hold_until(&scheduler.config));
            state.save(config_path)?;
            Ok(applied_json(&applied))
        }
        // Hand control back to the schedule and settle on the scheduled phase.
        "auto" => {
            let scheduler = scheduler.lock().await;
            let mut state = State::load(config_path);
            state.clear_manual();
            let phase = phase_at(&scheduler.config.schedule, now_local());
            let applied = device::apply_phase(&scheduler.config, &mut state, phase).await?;
            let name = match phase {
                crate::schedule::Phase::Off => "off",
                crate::schedule::Phase::On => "on",
            };
            state.record(name, "scheduled", &applied)?;
            state.save(config_path)?;
            Ok(applied_json(&applied))
        }
        "schedule" => {
            let off = parts.next().context("schedule needs OFF ON")?;
            let on = parts.next().context("schedule needs OFF ON")?;
            parse_clock(off).with_context(|| format!("invalid time {off}"))?;
            parse_clock(on).with_context(|| format!("invalid time {on}"))?;
            let mut scheduler = scheduler.lock().await;
            scheduler.config.schedule.off = off.to_string();
            scheduler.config.schedule.on = on.to_string();
            save_config(&scheduler.config, config_path)?;
            Ok(serde_json::json!({ "ok": true }).to_string())
        }
        "restore" => {
            let mode = parts.next().context("restore needs MODE [COLOR]")?;
            let mode = match mode {
                "captured" => RestoreMode::Captured,
                "fixed" => RestoreMode::Fixed,
                other => bail!("unknown restore mode {other}"),
            };
            let color = match parts.next() {
                Some(hex) => parse_hex_color(hex)?,
                None => parse_hex_color(&scheduler.lock().await.config.restore.color)?,
            };
            let mut scheduler = scheduler.lock().await;
            scheduler.config.restore.mode = mode;
            scheduler.config.restore.color = format_hex_color(color);
            save_config(&scheduler.config, config_path)?;
            Ok(serde_json::json!({ "ok": true }).to_string())
        }
        "reload" => {
            let mut scheduler = scheduler.lock().await;
            scheduler.config = Config::load_or_default(config_path)?;
            Ok(serde_json::json!({ "ok": true }).to_string())
        }
        "" => bail!("empty request"),
        other => bail!("unknown request {other}"),
    }
}

/// How long a manual on/off should hold: until the schedule next changes phase.
///
/// Without that hand-back a manual "off" at noon would silently disable the
/// 22:00 lights-out for good, which is the opposite of what the app promises.
fn hold_until(config: &Config) -> Option<chrono::DateTime<chrono::Local>> {
    crate::schedule::manual_hold(&config.schedule)
}

fn save_config(config: &Config, config_path: &Path) -> Result<()> {
    let text = config.to_toml()?;
    std::fs::write(config_path, text)
        .with_context(|| format!("write {}", config_path.display()))?;
    Ok(())
}

fn applied_json(applied: &[crate::state::AppliedDevice]) -> String {
    serde_json::json!({ "ok": true, "applied": applied }).to_string()
}

#[derive(Serialize)]
struct Status {
    /// Phase that is actually in force right now, manual override included.
    phase: &'static str,
    /// Whether a manual on/off is holding instead of the schedule.
    manual: bool,
    device: String,
    devices: Vec<String>,
    off: String,
    on: String,
    next: Option<String>,
    mode: String,
    color: String,
    captured: String,
    updated: Option<String>,
    action: Option<String>,
    permission: bool,
}

fn status(scheduler: &Scheduler, config_path: &Path) -> Status {
    let config = &scheduler.config;
    let state = State::load(config_path);
    let now = now_local();
    let scheduled = phase_at(&config.schedule, now);
    let manual = state.active_manual().map(str::to_string);
    // The panel shows what the lights are doing, so a manual choice wins here
    // too; otherwise it would claim "scheduled off" while the lights are on.
    let phase = match manual.as_deref() {
        Some("off") => "off",
        Some(_) => "on",
        None => match scheduled {
            crate::schedule::Phase::Off => "off",
            crate::schedule::Phase::On => "on",
        },
    };
    let devices: Vec<String> = state
        .applied
        .iter()
        .map(|device| device.name.clone())
        .collect();
    let device = devices.first().cloned().unwrap_or_else(|| "no device".into());
    let captured = state
        .captured
        .values()
        .next()
        .cloned()
        .unwrap_or_else(|| config.restore.fallback.clone());
    // While an override holds, the next change is when it lapses.
    let next = match manual.is_some() {
        true => state
            .manual_until
            .as_deref()
            .and_then(|at| chrono::DateTime::parse_from_rfc3339(at).ok())
            .map(|at| at.to_rfc3339()),
        false => next_boundary(&config.schedule, now).map(|at| at.to_rfc3339()),
    };
    Status {
        phase,
        manual: manual.is_some(),
        device,
        devices,
        off: config.schedule.off.clone(),
        on: config.schedule.on.clone(),
        next,
        mode: match config.restore.mode {
            RestoreMode::Captured => "captured".into(),
            RestoreMode::Fixed => "fixed".into(),
        },
        color: config.restore.color.clone(),
        captured,
        updated: state.updated_at.clone(),
        action: state.last_action.clone(),
        permission: openlogi_hid::permissions::has_access(),
    }
}
