//! Small shared helpers: colour parsing, the worker runtime, and the clock.

use std::time::Duration;

use anyhow::{bail, Result};
use chrono::{DateTime, Local};
use serde::{Deserialize, Serialize};

/// An RGB colour with eight bits per channel.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Rgb {
    /// Red channel.
    pub r: u8,
    /// Green channel.
    pub g: u8,
    /// Blue channel.
    pub b: u8,
}

impl Rgb {
    /// Build a colour from its channels.
    #[must_use]
    pub const fn new(r: u8, g: u8, b: u8) -> Self {
        Self { r, g, b }
    }

    /// The channels as a tuple.
    #[must_use]
    pub const fn components(self) -> (u8, u8, u8) {
        (self.r, self.g, self.b)
    }
}

/// Parse six hex digits, with or without a leading `#`.
pub fn parse_hex_color(input: &str) -> Result<Rgb> {
    let trimmed = input.trim().trim_start_matches('#');
    if trimmed.len() != 6 || !trimmed.chars().all(|c| c.is_ascii_hexdigit()) {
        bail!("invalid colour {input:?}: expected six hex digits, e.g. ff8800");
    }
    let value = u32::from_str_radix(trimmed, 16)?;
    Ok(Rgb::new(
        ((value >> 16) & 0xff) as u8,
        ((value >> 8) & 0xff) as u8,
        (value & 0xff) as u8,
    ))
}

/// Render a colour as six lowercase hex digits (no `#`).
#[must_use]
pub fn format_hex_color(color: Rgb) -> String {
    let (r, g, b) = color.components();
    format!("{r:02x}{g:02x}{b:02x}")
}

/// The current local wall-clock time.
#[must_use]
pub fn now_local() -> DateTime<Local> {
    Local::now()
}

/// Format a duration for log lines.
#[must_use]
pub fn human_duration(duration: Duration) -> String {
    let seconds = duration.as_secs();
    let hours = seconds / 3600;
    let minutes = (seconds % 3600) / 60;
    if hours > 0 {
        format!("{hours}h{minutes:02}m")
    } else if minutes > 0 {
        format!("{minutes}m{:02}s", seconds % 60)
    } else {
        format!("{seconds}s")
    }
}

/// Build the current-thread runtime every command runs on.
///
/// The HID layer is async but every command is a straight-line sequence, so a
/// current-thread runtime keeps the process small.
pub fn runtime() -> Result<tokio::runtime::Runtime> {
    Ok(tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?)
}
