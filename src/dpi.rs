//! DPI for the pointing device.
//!
//! DPI lives in the mouse, not in `config.toml`: the device is the only source
//! of truth, so every read goes to the hardware and every write is read back
//! before it is reported.

use anyhow::{Context, Result, anyhow};
use openlogi_core::hid::{Dpi, DpiInfo};

use crate::config::Config;
use crate::device;

/// What the window and the CLI need to show: the value in force plus the range
/// the device accepts, so a slider cannot offer something it will reject.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DpiReport {
    pub current: u16,
    pub min: u16,
    pub max: u16,
    pub step: u16,
    /// How many discrete values the device reports.
    pub values: usize,
}

impl DpiReport {
    fn from_info(info: &DpiInfo) -> Self {
        let capabilities = &info.capabilities;
        Self {
            current: info.current.into_inner(),
            min: capabilities.min().into_inner(),
            max: capabilities.max().into_inner(),
            step: capabilities.step_hint().into_inner(),
            values: capabilities.values().len(),
        }
    }
}

/// The pointing device DPI applies to: the first mouse or trackball found.
async fn pointer(config: &Config) -> Result<device::FoundDevice> {
    device::pointing_devices(config)
        .await?
        .into_iter()
        .next()
        .ok_or_else(|| anyhow!("no mouse or trackball found"))
}

/// Read the current DPI and the device's supported range.
pub async fn read(config: &Config) -> Result<DpiReport> {
    let found = pointer(config).await?;
    let info = openlogi_hid::get_dpi_info(&found.route)
        .await
        .map_err(|error| anyhow!("read DPI from {}: {error}", found.name))?;
    Ok(DpiReport::from_info(&info))
}

/// Write a DPI value, snapped to the nearest value the device accepts, then
/// read it back so the caller reports what the hardware actually took.
pub async fn write(config: &Config, requested: u16) -> Result<DpiReport> {
    let found = pointer(config).await?;
    let before = openlogi_hid::get_dpi_info(&found.route)
        .await
        .map_err(|error| anyhow!("read DPI from {}: {error}", found.name))?;
    let target = before.capabilities.nearest(Dpi::new(requested));
    if target != before.current {
        openlogi_hid::set_dpi(&found.route, target)
            .await
            .map_err(|error| {
                anyhow!(
                    "write DPI {} to {}: {error}",
                    target.into_inner(),
                    found.name
                )
            })?;
    }
    let after = openlogi_hid::get_dpi_info(&found.route)
        .await
        .context("read DPI back after writing it")?;
    Ok(DpiReport::from_info(&after))
}

#[cfg(test)]
mod tests {
    use super::DpiReport;
    use openlogi_core::hid::{Dpi, DpiCapabilities, DpiInfo};

    fn info(current: u16, values: Vec<u16>) -> DpiInfo {
        DpiInfo {
            current: Dpi::new(current),
            capabilities: DpiCapabilities::new(values).expect("non-empty list"),
        }
    }

    #[test]
    fn a_report_carries_the_range_and_the_smallest_step() {
        let report = DpiReport::from_info(&info(1600, vec![100, 150, 1600, 25600]));
        assert_eq!(report.current, 1600);
        assert_eq!(report.min, 100);
        assert_eq!(report.max, 25600);
        assert_eq!(report.step, 50);
        assert_eq!(report.values, 4);
    }

    #[test]
    fn a_request_snaps_to_the_nearest_value_the_device_lists() {
        let info = info(1600, vec![100, 150, 1600, 25600]);
        let nearest = |value| info.capabilities.nearest(Dpi::new(value)).into_inner();
        assert_eq!(nearest(1610), 1600);
        assert_eq!(nearest(3000), 1600);
        assert_eq!(nearest(20000), 25600);
        assert_eq!(nearest(0), 100);
    }
}
