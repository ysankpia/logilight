//! Device discovery and lighting writes.
//!
//! Discovery and routing come from OpenLogi's device layer; the write itself is
//! [`openlogi_hid::set_keyboard_color`], which drives HID++ `0x8070`
//! `ColorLedEffects` (the G502's engine) and falls back through `0x8071`,
//! `0x8081`, and `0x8080`. Reading the live colour is not part of that public
//! API, so this module opens the same channel and reads `0x8070` directly.

use anyhow::{Context, Result, anyhow};
use hidpp::device::Device;
use hidpp::feature::color_led_effects::ColorLedEffectsFeature;
use hidpp::feature::rgb_effects::{RgbEffectsFeature, RgbPowerModeConfig, SwControlFlags};
use openlogi_core::device::{DeviceInventory, DeviceKind};
use openlogi_hid::{DeviceRoute, dump_features};
use std::sync::Arc;
use std::time::Duration;

use crate::config::{Config, OFF_COLOR, state_path};
use crate::state::{AppliedDevice, State};
use crate::util::{Rgb, format_hex_color, now_local};

/// HID++ features that can drive a solid colour, in the order OpenLogi tries
/// them. A device with none of these is not a lighting target.
const LIGHTING_FEATURES: [u16; 4] = [0x8070, 0x8071, 0x8081, 0x8080];

/// `ColorLedEffects` feature id, read back for the live colour.
const COLOR_LED_EFFECTS: u16 = 0x8070;

/// `RgbEffects` feature id: the engine a device without `0x8070` writes
/// through, and the one whose software-control flag has to be handed back.
const RGB_EFFECTS: u16 = 0x8071;

/// What `AppliedDevice.color` says when the device took its LEDs back.
pub const RELEASED: &str = "released";

/// Attempts per colour write. An idle device drops the first HID++ request
/// after a wake, and a channel the pool replaced mid-flight fails the same
/// way; retrying keeps the transition inside the tick that scheduled it
/// instead of leaving the lights wrong until the next one.
const WRITE_ATTEMPTS: u32 = 3;

/// Pause between write attempts. A failed attempt already spends the HID++
/// request timeout, so this only separates the two.
const WRITE_RETRY_DELAY: Duration = Duration::from_millis(500);

/// One controllable device found on this host.
#[derive(Debug, Clone)]
pub struct FoundDevice {
    /// Human-readable name (firmware codename when reported).
    pub name: String,
    /// Route used to open the device.
    pub route: DeviceRoute,
    /// Classification from the inventory.
    pub kind: String,
    /// Whether the device advertises a lighting feature.
    pub lighting: bool,
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
    Ok(candidates(config, probe)
        .await?
        .into_iter()
        .filter(|device| device.lighting)
        .collect())
}

/// Pointing devices: the ones a DPI setting belongs to.
pub async fn pointing_devices(config: &Config) -> Result<Vec<FoundDevice>> {
    Ok(candidates(config, false)
        .await?
        .into_iter()
        .filter(|device| matches!(device.kind.as_str(), "mouse" | "trackball"))
        .collect())
}

/// Every online device that passes the config filter, lighting or not.
pub async fn candidates(config: &Config, probe: bool) -> Result<Vec<FoundDevice>> {
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
            if !config.devices.matches(vendor_id, product_id, &name) {
                continue;
            }
            if !is_lighting_target(paired.kind) {
                continue;
            }
            // The inventory's measured capability wins; without one, a probe
            // answers, and an unprobed device is given the benefit of the doubt.
            let lighting = match paired.capabilities.as_ref() {
                Some(caps) => caps.lighting,
                None if probe => has_lighting_feature(&route).await,
                None => true,
            };
            found.push(FoundDevice {
                name,
                route,
                kind: format!("{:?}", paired.kind).to_lowercase(),
                lighting,
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
    let mut applied = Vec::new();
    let mut failures = Vec::new();
    for device in devices {
        match write_color(&device.route, color).await {
            Ok(()) => applied.push(AppliedDevice {
                name: device.name.clone(),
                route: device.route.to_string(),
                color: format_hex_color(color),
            }),
            Err(error) => failures.push(format!("{}: {error}", device.name)),
        }
    }
    finish_apply(applied, failures)
}

/// Report one colour write to one device, retrying a dropped request.
pub(crate) async fn write_color(route: &DeviceRoute, color: Rgb) -> Result<()> {
    let (r, g, b) = color.components();
    retry_write(|| openlogi_hid::set_keyboard_color(route, r, g, b)).await
}

/// Run `attempt` until it succeeds or [`WRITE_ATTEMPTS`] are spent, keeping
/// every failure so the log names what each attempt returned.
async fn retry_write<T, E, F, Fut>(mut attempt: F) -> Result<T>
where
    E: std::fmt::Display,
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = std::result::Result<T, E>>,
{
    let mut failures = Vec::new();
    for index in 1..=WRITE_ATTEMPTS {
        match attempt().await {
            Ok(value) => return Ok(value),
            Err(error) => failures.push(format!("attempt {index}: {error}")),
        }
        if index < WRITE_ATTEMPTS {
            tokio::time::sleep(WRITE_RETRY_DELAY).await;
        }
    }
    Err(anyhow!("{}", failures.join("; ")))
}

/// Turn per-device outcomes into the result every caller expects: an error
/// only when no device took the colour, and a warning per partial failure.
fn finish_apply(applied: Vec<AppliedDevice>, failures: Vec<String>) -> Result<Vec<AppliedDevice>> {
    if applied.is_empty() && !failures.is_empty() {
        return Err(anyhow!(
            "no device accepted the colour: {}",
            failures.join("; ")
        ));
    }
    for failure in failures {
        eprintln!("warning: {failure}");
    }
    Ok(applied)
}

/// Turn lighting off.
///
/// Every lighting device is written, including one that cannot report its
/// colour: the G102 has no `0x8070` read-back, and skipping it would leave the
/// lights on all night. The colour is still captured where it can be read, for
/// the devices that have to be repainted at dawn.
pub async fn apply_off(config: &Config, state: &mut State) -> Result<Vec<AppliedDevice>> {
    let devices = lighting_devices(config, false).await?;
    for device in &devices {
        if let Ok(Some(color)) = read_color(&device.route).await {
            // A colour that is already black means there is nothing worth
            // restoring; recording it would leave the mouse dark at dawn.
            if color != OFF_COLOR {
                state.captured.insert(device.key(), format_hex_color(color));
            }
        }
    }
    apply_rgb_to(&devices, OFF_COLOR).await
}

/// Hand the lights back when the off window ends.
///
/// Releasing is the point: the device's own effect (or whatever G HUB last
/// applied) returns without this tool knowing what it was. Only a device that
/// cannot be released is repainted, with the colour captured at lights-out.
pub async fn apply_on_color(config: &Config, state: &mut State) -> Result<Vec<AppliedDevice>> {
    let devices = lighting_devices(config, false).await?;
    let fallback = crate::util::parse_hex_color(&config.restore.fallback)?;
    let mut applied = Vec::new();
    let mut failures = Vec::new();
    for device in &devices {
        match release_lighting(&device.route).await {
            Ok(true) => {
                applied.push(AppliedDevice {
                    name: device.name.clone(),
                    route: device.route.to_string(),
                    color: RELEASED.to_string(),
                });
                continue;
            }
            Ok(false) => {}
            Err(error) => {
                failures.push(format!("{}: {error}", device.name));
                continue;
            }
        }
        let color = state
            .captured
            .get(&device.key())
            .and_then(|hex| crate::util::parse_hex_color(hex).ok())
            .unwrap_or(fallback);
        match write_color(&device.route, color).await {
            Ok(()) => applied.push(AppliedDevice {
                name: device.name.clone(),
                route: device.route.to_string(),
                color: format_hex_color(color),
            }),
            Err(error) => failures.push(format!("{}: {error}", device.name)),
        }
    }
    finish_apply(applied, failures)
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

/// The device's own idle-lighting configuration: how long without activity
/// before the RGB engine dims, and before it goes dark.
#[derive(Debug, Clone, Copy)]
pub struct PowerConfig {
    pub flags: u16,
    pub power_save_seconds: u16,
    pub off_seconds: u16,
}

impl PowerConfig {
    fn from_raw(config: &RgbPowerModeConfig) -> Self {
        Self {
            flags: config.flags,
            power_save_seconds: config.no_activity_timeout_to_power_save,
            off_seconds: config.no_activity_timeout_to_off,
        }
    }
}

/// Open a device and resolve its `0x8071` engine, if it has one.
async fn open_rgb_effects(route: &DeviceRoute) -> Result<Option<(Device, Arc<RgbEffectsFeature>)>> {
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
        .get_feature(RGB_EFFECTS)
        .await
        .map_err(|error| anyhow!("resolve 0x8071 on {route}: {error}"))?
    else {
        return Ok(None);
    };
    let feature = device.add_feature::<RgbEffectsFeature>(info.index);
    Ok(Some((device, feature)))
}

/// Read the idle-lighting timeouts from the device, when it has the engine.
pub async fn power_config(route: &DeviceRoute) -> Result<Option<PowerConfig>> {
    let Some((_device, feature)) = open_rgb_effects(route).await? else {
        return Ok(None);
    };
    let config = feature
        .get_power_mode_config()
        .await
        .map_err(|error| anyhow!("read 0x8071 power mode on {route}: {error}"))?;
    Ok(Some(PowerConfig::from_raw(&config)))
}

/// Ask the device to turn its own lighting off after `seconds` without input.
///
/// This is the "lighting sleep timer" the hardware ships with: the firmware
/// counts the idle time, so nothing has to stay running. `0` disables it.
pub async fn set_idle_off(route: &DeviceRoute, seconds: u16) -> Result<PowerConfig> {
    let Some((_device, feature)) = open_rgb_effects(route).await? else {
        return Err(anyhow!("{route} has no 0x8071 engine"));
    };
    let mut config = feature
        .get_power_mode_config()
        .await
        .map_err(|error| anyhow!("read 0x8071 power mode on {route}: {error}"))?;
    config.no_activity_timeout_to_off = seconds;
    feature
        .set_power_mode_config(config)
        .await
        .map_err(|error| anyhow!("write 0x8071 power mode on {route}: {error}"))?;
    let after = feature
        .get_power_mode_config()
        .await
        .map_err(|error| anyhow!("read 0x8071 power mode back on {route}: {error}"))?;
    Ok(PowerConfig::from_raw(&after))
}

/// Hand LED control back to the firmware so the device shows its own effect.
///
/// A colour write takes software control of the LEDs and leaves it held; the
/// firmware keeps replaying nothing while that flag is set. A device this tool
/// never manages — one whose colour cannot be read — would otherwise stay on
/// the last static colour written by an older build. Returns whether control
/// was actually held.
pub async fn release_lighting(route: &DeviceRoute) -> Result<bool> {
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
        .get_feature(RGB_EFFECTS)
        .await
        .map_err(|error| anyhow!("resolve 0x8071 on {route}: {error}"))?
    else {
        return Ok(false);
    };
    let feature = device.add_feature::<RgbEffectsFeature>(info.index);
    let state = feature
        .get_sw_control()
        .await
        .map_err(|error| anyhow!("read 0x8071 control on {route}: {error}"))?;
    if !state.control.contains(SwControlFlags::ALL_CLUSTERS) {
        return Ok(false);
    }
    feature
        .set_sw_control(
            state.control.difference(SwControlFlags::ALL_CLUSTERS),
            state.events,
        )
        .await
        .map_err(|error| anyhow!("release 0x8071 control on {route}: {error}"))?;
    Ok(true)
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
            crate::util::human_duration((boundary - now_local()).to_std().unwrap_or_default())
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

#[cfg(test)]
mod tests {
    use super::{WRITE_ATTEMPTS, retry_write};
    use std::cell::Cell;

    #[tokio::test]
    async fn a_dropped_request_is_retried_until_it_lands() {
        let attempts = Cell::new(0);
        let result = retry_write(|| {
            let attempt = attempts.get() + 1;
            attempts.set(attempt);
            async move {
                if attempt < WRITE_ATTEMPTS {
                    Err("HID++ request timed out")
                } else {
                    Ok("written")
                }
            }
        })
        .await;

        assert_eq!(result.unwrap(), "written");
        assert_eq!(attempts.get(), WRITE_ATTEMPTS);
    }

    #[tokio::test]
    async fn every_failure_names_its_attempt() {
        let attempts = Cell::new(0);
        let result = retry_write(|| {
            let attempt = attempts.get() + 1;
            attempts.set(attempt);
            async move { Err::<(), _>(format!("failure {attempt}")) }
        })
        .await;

        let message = result.unwrap_err().to_string();
        assert_eq!(attempts.get(), WRITE_ATTEMPTS);
        for attempt in 1..=WRITE_ATTEMPTS {
            assert!(
                message.contains(&format!("attempt {attempt}: failure {attempt}")),
                "missing attempt {attempt} in {message:?}"
            );
        }
    }
}
