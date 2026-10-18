//! Persisted scheduler state: the phase last applied and the colours captured
//! before each lights-out.
//!
//! State is deliberately separate from the config: it is machine-local and
//! rewritten by the daemon, while the config is hand-edited.

use std::collections::BTreeMap;
use std::path::Path;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::util::now_local;

/// One device that accepted a write.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppliedDevice {
    /// Name reported by the device.
    pub name: String,
    /// Route it was reached on.
    pub route: String,
    /// Colour written, six hex digits.
    pub color: String,
}

/// Everything the daemon remembers across restarts.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct State {
    /// Phase last applied: `on` or `off`.
    pub phase: String,
    /// When the last write happened (RFC 3339, local offset).
    pub updated_at: Option<String>,
    /// What the last write was: `scheduled`, `off`, `on`, `manual`, `arrival`.
    pub last_action: Option<String>,
    /// Per-route colour that was live before lighting was turned off.
    pub captured: BTreeMap<String, String>,
    /// Devices that accepted the most recent write.
    pub applied: Vec<AppliedDevice>,
    /// Manual override phase (`on`/`off`) chosen in the settings app.
    ///
    /// While it holds, the daemon keeps this phase instead of the schedule, so
    /// a manual choice is not undone by the next tick.
    pub manual: Option<String>,
    /// When the override stops applying (RFC 3339, next scheduled boundary).
    pub manual_until: Option<String>,
}

impl State {
    /// Load state next to the config, falling back to an empty state.
    ///
    /// A corrupt state file must not stop the daemon: losing the captured
    /// colour is recoverable, a daemon that refuses to start is not.
    #[must_use]
    pub fn load(config_path: &Path) -> Self {
        let path = crate::config::state_path(config_path);
        let Ok(text) = std::fs::read_to_string(&path) else {
            return Self::default();
        };
        serde_json::from_str(&text).unwrap_or_default()
    }

    /// Write state atomically next to the config.
    pub fn save(&self, config_path: &Path) -> Result<()> {
        let path = crate::config::state_path(config_path);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("create {}", parent.display()))?;
        }
        let temporary = path.with_extension("json.tmp");
        let text = serde_json::to_string_pretty(self)?;
        std::fs::write(&temporary, text)
            .with_context(|| format!("write {}", temporary.display()))?;
        std::fs::rename(&temporary, &path)
            .with_context(|| format!("replace {}", path.display()))?;
        Ok(())
    }

    /// Record a completed write.
    pub fn record(&mut self, phase: &str, action: &str, applied: &[AppliedDevice]) -> Result<()> {
        self.phase = phase.to_string();
        self.last_action = Some(action.to_string());
        self.updated_at = Some(now_local().to_rfc3339());
        self.applied = applied.to_vec();
        Ok(())
    }

    /// The manual phase that should win right now, if the override still holds.
    ///
    /// The override expires at the next scheduled boundary so a manual choice
    /// lasts until the schedule would have acted anyway, then hands control
    /// back on its own. Without an expiry it holds until it is cleared.
    #[must_use]
    pub fn active_manual(&self) -> Option<&str> {
        let phase = self.manual.as_deref()?;
        if phase != "on" && phase != "off" {
            return None;
        }
        let Some(until) = self.manual_until.as_deref() else {
            return Some(phase);
        };
        let until = chrono::DateTime::parse_from_rfc3339(until).ok()?;
        (now_local() < until.with_timezone(&now_local().timezone())).then_some(phase)
    }

    /// Hold `phase` manually until `until` (`None` holds it indefinitely).
    pub fn set_manual(&mut self, phase: &str, until: Option<chrono::DateTime<chrono::Local>>) {
        self.manual = Some(phase.to_string());
        self.manual_until = until.map(|at| at.to_rfc3339());
    }

    /// Drop the override so the schedule takes over again.
    pub fn clear_manual(&mut self) {
        self.manual = None;
        self.manual_until = None;
    }
}

#[cfg(test)]
mod tests {
    use chrono::{Duration, Local};

    use super::State;

    fn held(offset: Duration) -> State {
        let mut state = State::default();
        state.set_manual("off", Some(Local::now() + offset));
        state
    }

    #[test]
    fn a_manual_choice_holds_until_its_deadline() {
        assert_eq!(held(Duration::minutes(30)).active_manual(), Some("off"));
        assert_eq!(held(Duration::minutes(-1)).active_manual(), None);
    }

    #[test]
    fn a_manual_choice_without_a_deadline_holds_forever() {
        let mut state = State::default();
        state.set_manual("on", None);
        assert_eq!(state.active_manual(), Some("on"));
    }

    #[test]
    fn clearing_the_override_hands_control_back() {
        let mut state = held(Duration::hours(2));
        state.clear_manual();
        assert_eq!(state.active_manual(), None);
        assert!(state.manual.is_none());
    }

    #[test]
    fn an_unrecognised_phase_is_ignored() {
        let mut state = held(Duration::hours(2));
        state.manual = Some("banana".to_string());
        assert_eq!(state.active_manual(), None);
    }
}
