//! Device discovery and lighting writes.
//!
//! Discovery and routing come from OpenLogi's device layer; the write itself is
//! [`openlogi_hid::set_keyboard_color`], which drives HID++ `0x8070`
//! `ColorLedEffects` (the G502's engine) and falls back through `0x8071`,
//! `0x8081`, and `0x8080`. Reading the live colour is not part of that public
//! API, so this module opens the same channel and reads `0x8070` directly.

use std::sync::Arc;
use anyhow::{Context, Result, anyhow};
use hidpp::device::Device;
use hidpp::feature::color_led_effects::ColorLedEffectsFeature;
use openlogi_core::device::{DeviceInventory, DeviceKind};
use openlogi_hid::{DeviceRoute, dump_features};

use crate::config::{Config, OFF_COLOR, RestoreMode, state_path};
use crate::state::{AppliedDevice, State};
use crate::util::{Rgb, format_hex_color, now_local};

/// HID++ features that can drive a solid colour, in the order OpenLogi tries
/// them. A device with none of these is not a lighting target.
const LIGHTING_FEATURES: [u16; 4] = [0x8070, 0x8071, 0x8081, 0x8080];

/// `ColorLedEffects` feature id, read back for the live colour.
const COLOR_LED_EFFECTS: u16 = 0x8070;

/// One controllable device found on this host.
#[derive(Debug, Clone)]
pub struct FoundDevice {
    /// Human-readable name (firmware codename when reported).
    pub name: String,
    /// Route used to open the device.
    pub route: DeviceRoute,
    /// Classification from the inventory.
    pub kind: String,
}

impl FoundDevice {
    /// Stable key for state and de-duplication.
    #[must_use]
    pub fn key(&self) -> String {
        self.route.to_string()
    }
}

/// Discover every online device that passes the config filter and advertises a
/// lighting feature.
///
/// `probe` forces a feature-table dump per candidate. Enumeration already
/// carries measured capabilities, so probing is only needed when the inventory
/// could not derive them (a device that answered pairing but not the probe).
pub async fn lighting_devices(config: &Config, probe: bool) -> Result<Vec<FoundDevice>> {
    let inventories = openlogi_hid::enumerate()
        .await
        .context("enumerate HID++ devices")?;
    let mut found = Vec::new();
    for inventory in &inventories {
        for paired in inventory.paired.iter().filter(|paired| paired.online) {
            let Some(route) = DeviceRoute::for_slot(inventory, paired.slot) else {
                continue;
            };
            let name = paired
                .codename
                .clone()
                .unwrap_or_else(|| inventory.receiver.name.clone());
            let (vendor_id, product_id) = route_ids(&route, inventory);
            if !config
                .devices
                .matches(vendor_id, product_id, &name)
            {
                continue;
            }
            if !is_lighting_target(paired.kind) {
                continue;
            }
            let advertised = paired.capabilities.as_ref().map_or(probe, |caps| caps.lighting);
            if !advertised {
                continue;
            }
            if probe && paired.capabilities.is_none() && !has_lighting_feature(&route).await {
                continue;
            }
            found.push(FoundDevice {
                name,
                route,
                kind: format!("{:?}", paired.kind).to_lowercase(),
            });
        }
    }
    Ok(found)
}

fn route_ids(route: &DeviceRoute, inventory: &DeviceInventory) -> (u16, u16) {
    match route {
        DeviceRoute::Direct {
            vendor_id,
            product_id,
        } => (*vendor_id, *product_id),
        _ => (inventory.receiver.vendor_id, inventory.receiver.product_id),
    }
}

/// Devices whose LEDs are worth driving. Keyboards are included because the
/// same HID++ engine backs their RGB; pointing this tool at one is harmless.
fn is_lighting_target(kind: DeviceKind) -> bool {
    matches!(
        kind,
        DeviceKind::Mouse
            | DeviceKind::Keyboard
            | DeviceKind::Trackball
            | DeviceKind::Numpad
            | DeviceKind::Unknown
    )
}

async fn has_lighting_feature(route: &DeviceRoute) -> bool {
    match dump_features(route).await {
        Ok(entries) => entries
            .iter()
            .any(|entry| LIGHTING_FEATURES.contains(&entry.id)),
        Err(_) => false,
    }
}

/// Write one colour to every selected device.
pub async fn apply_rgb(config: &Config, color: Rgb) -> Result<Vec<AppliedDevice>> {
    let devices = lighting_devices(config, false).await?;
    apply_rgb_to(&devices, color).await
}

async fn apply_rgb_to(devices: &[FoundDevice], color: Rgb) -> Result<Vec<AppliedDevice>> {
    let (r, g, b) = color.components();
    let mut applied = Vec::new();
    let mut failures = Vec::new();
    for device in devices {
        match openlogi_hid::set_keyboard_color(&device.route, r, g, b).await {
            Ok(()) => applied.push(AppliedDevice {
                name: device.name.clone(),
                route: device.route.to_string(),
                color: format_hex_color(color),
            }),
            Err(error) => failures.push(format!("{}: {error}", device.name)),
        }
    }
    if applied.is_empty() && !failures.is_empty() {
        return Err(anyhow!("no device accepted the colour: {}", failures.join("; ")));
    }
    for failure in failures {
        eprintln!("warning: {failure}");
    }
    Ok(applied)
}

/// Turn lighting off, capturing each device's live colour first.
pub async fn apply_off(config: &Config, state: &mut State) -> Result<Vec<AppliedDevice>> {
    let devices = lighting_devices(config, false).await?;
    for device in &devices {
        match read_color(&device.route).await {
            // A colour that is already black means there is nothing worth
            // restoring; recording it would leave the mouse dark at dawn.
            Ok(Some(color)) if color != OFF_COLOR => {
                state
                    .captured
                    .insert(device.key(), format_hex_color(color));
            }
            Ok(Some(_)) => {}
            Ok(None) | Err(_) => {}
        }
    }
    apply_rgb_to(&devices, OFF_COLOR).await
}

/// The colour to write when the off window ends.
pub async fn apply_on_color(config: &Config, state: &mut State) -> Result<Vec<AppliedDevice>> {
    let devices = lighting_devices(config, false).await?;
    let fallback = crate::util::parse_hex_color(&config.restore.fallback)?;
    let fixed = crate::util::parse_hex_color(&config.restore.color)?;
    let mut applied = Vec::new();
    let mut failures = Vec::new();
    for device in &devices {
        let color = match config.restore.mode {
            RestoreMode::Fixed => fixed,
            RestoreMode::Captured => state
                .captured
                .get(&device.key())
                .and_then(|hex| crate::util::parse_hex_color(hex).ok())
                .unwrap_or(fallback),
        };
        let (r, g, b) = color.components();
        match openlogi_hid::set_keyboard_color(&device.route, r, g, b).await {
            Ok(()) => applied.push(AppliedDevice {
                name: device.name.clone(),
                route: device.route.to_string(),
                color: format_hex_color(color),
            }),
            Err(error) => failures.push(format!("{}: {error}", device.name)),
        }
    }
    if applied.is_empty() && !failures.is_empty() {
        return Err(anyhow!("no device accepted the colour: {}", failures.join("; ")));
    }
    for failure in failures {
        eprintln!("warning: {failure}");
    }
    Ok(applied)
}

/// Read the live colour of a device through `0x8070`.
///
/// Returns `Ok(None)` when the device has no `0x8070` or does not implement the
/// colour read-back function; the caller then falls back to its configured
/// restore colour. Zone 0 is the primary zone on every device seen so far.
pub async fn read_color(route: &DeviceRoute) -> Result<Option<Rgb>> {
    let pool = openlogi_hid::channel_pool();
    let channel = pool
        .open(route)
        .await
        .map_err(|error| anyhow!("open {}: {error}", route))?
        .ok_or_else(|| anyhow!("device not connected: {route}"))?;
    let mut device = Device::new(Arc::clone(&channel), route.device_index())
        .await
        .map_err(|error| anyhow!("initialize device {route}: {error}"))?;
    let Some(info) = device
        .root()
        .get_feature(COLOR_LED_EFFECTS)
        .await
        .map_err(|error| anyhow!("resolve 0x8070 on {route}: {error}"))?
    else {
        return Ok(None);
    };
    let feature = device.add_feature::<ColorLedEffectsFeature>(info.index);
    let zone_count = feature
        .get_info()
        .await
        .map_err(|error| anyhow!("read 0x8070 info on {route}: {error}"))?
        .zone_count;
    let mut last = None;
    for zone in 0..zone_count.min(4) {
        match feature.get_current_color(zone).await {
            Ok(rgb) => {
                last = Some(Rgb::new(rgb.red, rgb.green, rgb.blue));
                if last != Some(OFF_COLOR) {
                    break;
                }
            }
            Err(_) => continue,
        }
    }
    Ok(last)
}

/// Record applied colours as the ones to restore after the next lights-out.
///
/// Only non-black writes qualify: remembering `000000` would restore a dark
/// mouse at dawn.
pub fn remember_colors(state: &mut State, applied: &[AppliedDevice]) {
    for entry in applied {
        if entry.color != format_hex_color(OFF_COLOR) {
            state
                .captured
                .insert(entry.route.clone(), entry.color.clone());
        }
    }
}

/// Apply one phase now and remember any colour it revealed.
///
/// Shared by the control channel and the CLI so `auto` means the same thing
/// whichever way it was asked for.
pub async fn apply_phase(
    config: &Config,
    state: &mut State,
    phase: crate::schedule::Phase,
) -> Result<Vec<AppliedDevice>> {
    let applied = match phase {
        crate::schedule::Phase::Off => apply_off(config, state).await?,
        crate::schedule::Phase::On => apply_on_color(config, state).await?,
    };
    remember_colors(state, &applied);
    Ok(applied)
}

/// Print the human-readable status used by `logilight status`.
pub async fn print_status(config: &Config, config_path: &std::path::Path) -> Result<()> {
    let state = State::load(config_path);
    println!("config:  {}", config_path.display());
    println!("state:   {}", state_path(config_path).display());
    println!("time:    {}", now_local().format("%Y-%m-%d %H:%M:%S %Z"));
    let phase = crate::schedule::phase_at(&config.schedule, now_local());
    println!(
        "schedule: {} (off {} → on {}, now {})",
        if config.schedule.enabled {
            "enabled"
        } else {
            "disabled"
        },
        config.schedule.off,
        config.schedule.on,
        match phase {
            crate::schedule::Phase::Off => "off",
            crate::schedule::Phase::On => "on",
        }
    );
    if let Some(boundary) = crate::schedule::next_boundary(&config.schedule, now_local()) {
        println!(
            "next change: {} (in {})",
            boundary.format("%Y-%m-%d %H:%M"),
            crate::util::human_duration(
                (boundary - now_local()).to_std().unwrap_or_default()
            )
        );
    }
    println!(
        "last applied: {} ({}){}",
        state.phase,
        state.updated_at.as_deref().unwrap_or("never"),
        state
            .last_action
            .as_deref()
            .map_or_else(String::new, |action| format!(" — {action}"))
    );
    if !state.captured.is_empty() {
        println!("captured colours:");
        for (route, color) in &state.captured {
            println!("  {route} → #{color}");
        }
    }
    let devices = lighting_devices(config, true).await?;
    println!("devices ({}):", devices.len());
    for device in &devices {
        let color = match read_color(&device.route).await {
            Ok(Some(rgb)) => format!("#{}", format_hex_color(rgb)),
            Ok(None) => "unreadable".to_string(),
            Err(error) => format!("error: {error:#}"),
        };
        println!("  {} [{}] current={color}", device.name, device.route);
    }
    if devices.is_empty() {
        println!("  (none — is the mouse connected and awake?)");
    }
    Ok(())
}
