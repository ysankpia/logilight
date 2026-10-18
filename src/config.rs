//! Configuration file handling.
//!
//! The file is plain TOML so it can be edited by hand and kept in a dotfiles
//! repository. Unknown keys are rejected: a typo in a schedule must be an
//! error, not a silently ignored rule.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::util::Rgb;

/// The colour written when lighting is "off".
pub const OFF_COLOR: Rgb = Rgb::new(0, 0, 0);

/// Which devices the scheduler drives.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct DeviceFilter {
    /// Only drive devices whose name contains one of these strings
    /// (case-insensitive). Empty means every lighting-capable HID++ device.
    pub names: Vec<String>,
    /// Only drive devices with this USB/HID vendor id.
    pub vendor_id: Option<u16>,
    /// Only drive devices with one of these USB/HID product ids.
    pub product_ids: Vec<u16>,
}

impl DeviceFilter {
    /// Whether a discovered device passes the filter.
    pub fn matches(&self, vendor_id: u16, product_id: u16, name: &str) -> bool {
        if let Some(wanted) = self.vendor_id
            && vendor_id != wanted
        {
            return false;
        }
        if !self.product_ids.is_empty() && !self.product_ids.contains(&product_id) {
            return false;
        }
        if !self.names.is_empty() {
            let lowered = name.to_lowercase();
            if !self
                .names
                .iter()
                .any(|needle| lowered.contains(&needle.to_lowercase()))
            {
                return false;
            }
        }
        true
    }
}

/// A daily off/on window.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Schedule {
    /// Whether the schedule runs at all.
    pub enabled: bool,
    /// Local wall-clock time to turn lighting off, `HH:MM`.
    pub off: String,
    /// Local wall-clock time to restore lighting, `HH:MM`.
    pub on: String,
    /// Re-check the clock this often, in seconds. The timer is also woken at
    /// exact boundaries, so this only bounds drift and sleep/wake recovery.
    pub tick_seconds: u64,
    /// Re-apply the current state when a device appears (for example after a
    /// mouse wakes from sleep and the firmware forgot its RAM-only colour).
    pub reapply_on_arrival: bool,
    /// How often to scan for newly connected devices and for colour drift, in
    /// seconds.
    pub scan_seconds: u64,
}

impl Default for Schedule {
    fn default() -> Self {
        Self {
            enabled: true,
            off: "22:00".to_string(),
            on: "07:00".to_string(),
            tick_seconds: 30,
            reapply_on_arrival: true,
            scan_seconds: 20,
        }
    }
}

/// The colour restored when the off window ends.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Restore {
    /// `captured` restores whatever colour was on the mouse before the last
    /// "off"; `fixed` always uses [`Self::color`].
    pub mode: RestoreMode,
    /// Colour used by [`RestoreMode::Fixed`], six hex digits.
    pub color: String,
    /// Colour to restore when nothing was captured (for example the first run
    /// happened during the night window).
    pub fallback: String,
}

impl Default for Restore {
    fn default() -> Self {
        Self {
            mode: RestoreMode::Captured,
            color: "ffffff".to_string(),
            fallback: "ffffff".to_string(),
        }
    }
}

/// How the "on" time decides which colour to write.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RestoreMode {
    /// Restore the colour that was live before lighting was turned off.
    Captured,
    /// Always restore [`Restore::color`].
    Fixed,
}

/// Everything the daemon reads from disk.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    /// Which devices to drive.
    pub devices: DeviceFilter,
    /// The daily window.
    pub schedule: Schedule,
    /// What to restore when the window ends.
    pub restore: Restore,
    /// Write a line per transition to the log.
    pub verbose: bool,}

impl Default for Config {
    fn default() -> Self {
        Self {
            devices: DeviceFilter::default(),
            schedule: Schedule::default(),
            restore: Restore::default(),
            verbose: true,
        }
    }
}

impl Config {
    /// Load the config, creating the default file when it does not exist.
    pub fn load_or_default(path: &Path) -> Result<Self> {
        if !path.exists() {
            let config = Self::default();
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)
                    .with_context(|| format!("create {}", parent.display()))?;
            }
            std::fs::write(path, config.to_toml()?)
                .with_context(|| format!("write {}", path.display()))?;
            return Ok(config);
        }
        let text =
            std::fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
        let config: Self = toml::from_str(&text)
            .with_context(|| format!("parse {}", path.display()))?;
        config.validate()?;
        Ok(config)
    }

    /// Serialize back to TOML with the documenting comments intact.
    pub fn to_toml(&self) -> Result<String> {
        let mut out = String::new();
        out.push_str("# logilight — scheduled lighting control for Logitech mice.\n");
        out.push_str("# Edit and restart the agent: launchctl kickstart -k gui/$(id -u)/com.luhui.logilight\n\n");
        out.push_str("# Write a timestamped line per transition to the log.\n");
        out.push_str(&format!("verbose = {}\n\n", self.verbose));
        out.push_str("[devices]\n");
        out.push_str("# Case-insensitive substrings; empty means every lighting-capable device.\n");
        out.push_str(&format!("names = {}\n", toml_array(&self.devices.names)));
        match self.devices.vendor_id {
            Some(id) => out.push_str(&format!("vendor_id = {id}\n")),
            None => out.push_str("# vendor_id = 1133   # 0x046d\n"),
        }
        out.push_str(&format!(
            "product_ids = {}\n\n",
            toml_u16_array(&self.devices.product_ids)
        ));
        out.push_str("[schedule]\n");
        out.push_str(&format!("enabled = {}\n", self.schedule.enabled));
        out.push_str(&format!("# Local wall-clock times, HH:MM.\noff = \"{}\"\n", self.schedule.off));
        out.push_str(&format!("on = \"{}\"\n", self.schedule.on));
        out.push_str(&format!("tick_seconds = {}\n", self.schedule.tick_seconds));
        out.push_str(&format!(
            "reapply_on_arrival = {}\n",
            self.schedule.reapply_on_arrival
        ));
        out.push_str(&format!("scan_seconds = {}\n\n", self.schedule.scan_seconds));
        out.push_str("[restore]\n");
        out.push_str("# \"captured\" = the colour that was live before lights-out.\n");
        out.push_str("# \"fixed\"    = always use `color` below.\n");
        out.push_str(&format!("mode = \"{}\"\n", match self.restore.mode {
            RestoreMode::Captured => "captured",
            RestoreMode::Fixed => "fixed",
        }));
        out.push_str(&format!("color = \"{}\"\n", self.restore.color));
        out.push_str(&format!("# Used when nothing was captured.\nfallback = \"{}\"\n", self.restore.fallback));
        Ok(out)
    }

    /// Reject values that would make the daemon behave unexpectedly.
    pub fn validate(&self) -> Result<()> {
        crate::schedule::parse_clock(&self.schedule.off)
            .with_context(|| "schedule.off must be HH:MM")?;
        crate::schedule::parse_clock(&self.schedule.on)
            .with_context(|| "schedule.on must be HH:MM")?;
        crate::util::parse_hex_color(&self.restore.color)
            .with_context(|| "restore.color must be six hex digits")?;
        crate::util::parse_hex_color(&self.restore.fallback)
            .with_context(|| "restore.fallback must be six hex digits")?;
        if self.schedule.tick_seconds == 0 {
            anyhow::bail!("schedule.tick_seconds must be at least 1");
        }
        if self.schedule.scan_seconds == 0 {
            anyhow::bail!("schedule.scan_seconds must be at least 1");
        }
        Ok(())
    }
}

fn toml_array(values: &[String]) -> String {
    let quoted: Vec<String> = values
        .iter()
        .map(|value| format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\"")))
        .collect();
    format!("[{}]", quoted.join(", "))
}

fn toml_u16_array(values: &[u16]) -> String {
    let rendered: Vec<String> = values.iter().map(u16::to_string).collect();
    format!("[{}]", rendered.join(", "))
}

/// `~/Library/Application Support/logilight/config.toml`.
pub fn default_config_path() -> PathBuf {
    data_dir().join("config.toml")
}

/// `~/Library/Application Support/logilight`.
pub fn data_dir() -> PathBuf {
    let home = std::env::var_os("HOME").map_or_else(PathBuf::new, PathBuf::from);
    home.join("Library")
        .join("Application Support")
        .join("logilight")
}

/// State file written next to the config.
pub fn state_path(config_path: &Path) -> PathBuf {
    config_path
        .parent()
        .map_or_else(data_dir, Path::to_path_buf)
        .join("state.json")
}
