//! The daily window: deciding whether lighting should be on or off.

use chrono::{DateTime, Duration as ChronoDuration, Local, NaiveTime, TimeZone};
use serde::{Deserialize, Serialize};

use crate::config::Schedule;

/// What the schedule wants right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Phase {
    /// Outside the off window — lighting should be on.
    On,
    /// Inside the off window — lighting should be off.
    Off,
}

/// Parse `HH:MM` (or `H:MM`) into a wall-clock time.
pub fn parse_clock(input: &str) -> anyhow::Result<NaiveTime> {
    NaiveTime::parse_from_str(input.trim(), "%H:%M")
        .map_err(|_| anyhow::anyhow!("expected HH:MM, got {input:?}"))
}

/// The phase at `now` for a schedule.
///
/// Windows that cross midnight are the normal case (`22:00` → `07:00`): the
/// off window is `[off, on)` and the rest of the day is on. An `off` equal to
/// `on` is treated as a 24-hour window, matching the intuitive reading of
/// "turn it off and never turn it back on".
pub fn phase_at(schedule: &Schedule, now: DateTime<Local>) -> Phase {
    if !schedule.enabled {
        return Phase::On;
    }
    let Ok(off) = parse_clock(&schedule.off) else {
        return Phase::On;
    };
    let Ok(on) = parse_clock(&schedule.on) else {
        return Phase::On;
    };
    let time = now.time();
    let inside = if off == on {
        true
    } else if off < on {
        time >= off && time < on
    } else {
        time >= off || time < on
    };
    if inside { Phase::Off } else { Phase::On }
}

/// The next instant the phase changes, or `None` when the schedule is off.
pub fn next_boundary(schedule: &Schedule, now: DateTime<Local>) -> Option<DateTime<Local>> {
    if !schedule.enabled {
        return None;
    }
    let off = parse_clock(&schedule.off).ok()?;
    let on = parse_clock(&schedule.on).ok()?;
    let candidates = [next_occurrence(off, now), next_occurrence(on, now)];
    candidates.into_iter().flatten().min()
}

/// How long a manual on/off should hold before the schedule takes over.
///
/// The next boundary is the honest answer: the lights would have changed then
/// anyway, so a hand-set state never silently disables the nightly routine.
#[must_use]
pub fn manual_hold(schedule: &Schedule) -> Option<DateTime<Local>> {
    next_boundary(schedule, crate::util::now_local())
}

/// The next time-of-day occurrence strictly after `now`.
fn next_occurrence(time: NaiveTime, now: DateTime<Local>) -> Option<DateTime<Local>> {
    let today = now.date_naive();
    for offset in 0..=2 {
        let date = today + ChronoDuration::days(offset);
        let candidate = date.and_time(time);
        if let Some(local) = resolve_local(candidate, &now)
            && local > now
        {
            return Some(local);
        }
    }
    None
}

/// Turn a naive local time into an aware one, resolving DST gaps.
///
/// A spring-forward gap has no valid local time; the first instant after the
/// gap is the honest answer for a scheduler that just wants "when to run".
fn resolve_local(
    naive: chrono::NaiveDateTime,
    reference: &DateTime<Local>,
) -> Option<DateTime<Local>> {
    use chrono::LocalResult;
    match reference.timezone().from_local_datetime(&naive) {
        LocalResult::Single(value) => Some(value),
        LocalResult::Ambiguous(earlier, _later) => Some(earlier),
        LocalResult::None => {
            // Walk forward in one-minute steps until the clock is valid again.
            let mut probe = naive;
            for _ in 0..180 {
                probe += ChronoDuration::minutes(1);
                if let LocalResult::Single(value) = reference.timezone().from_local_datetime(&probe)
                {
                    return Some(value);
                }
            }
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use chrono::{Datelike, TimeZone, Timelike};

    use super::{Phase, next_boundary, parse_clock, phase_at};
    use crate::config::Schedule;

    fn at(hour: u32, minute: u32) -> chrono::DateTime<chrono::Local> {
        chrono::Local
            .with_ymd_and_hms(2026, 10, 18, hour, minute, 0)
            .single()
            .expect("a valid local time")
    }

    fn schedule(off: &str, on: &str) -> Schedule {
        Schedule {
            off: off.to_string(),
            on: on.to_string(),
            ..Schedule::default()
        }
    }

    #[test]
    fn parses_clock_values() {
        assert_eq!(parse_clock("22:00").expect("valid").hour(), 22);
        assert_eq!(parse_clock("7:05").expect("valid").minute(), 5);
        assert!(parse_clock("24:00").is_err());
        assert!(parse_clock("nope").is_err());
    }

    #[test]
    fn a_window_across_midnight_is_off_before_bed_and_on_in_the_morning() {
        let s = schedule("22:00", "07:00");
        assert_eq!(phase_at(&s, at(21, 59)), Phase::On);
        assert_eq!(phase_at(&s, at(22, 0)), Phase::Off);
        assert_eq!(phase_at(&s, at(23, 30)), Phase::Off);
        assert_eq!(phase_at(&s, at(0, 0)), Phase::Off);
        assert_eq!(phase_at(&s, at(6, 59)), Phase::Off);
        assert_eq!(phase_at(&s, at(7, 0)), Phase::On);
        assert_eq!(phase_at(&s, at(12, 0)), Phase::On);
    }

    #[test]
    fn a_daytime_window_is_off_inside_it() {
        let s = schedule("09:00", "17:00");
        assert_eq!(phase_at(&s, at(8, 59)), Phase::On);
        assert_eq!(phase_at(&s, at(9, 0)), Phase::Off);
        assert_eq!(phase_at(&s, at(16, 59)), Phase::Off);
        assert_eq!(phase_at(&s, at(17, 0)), Phase::On);
    }

    #[test]
    fn equal_times_mean_off_all_day() {
        let s = schedule("00:00", "00:00");
        assert_eq!(phase_at(&s, at(3, 0)), Phase::Off);
        assert_eq!(phase_at(&s, at(15, 0)), Phase::Off);
    }

    #[test]
    fn a_disabled_schedule_is_always_on() {
        let mut s = schedule("22:00", "07:00");
        s.enabled = false;
        assert_eq!(phase_at(&s, at(23, 0)), Phase::On);
        assert!(next_boundary(&s, at(23, 0)).is_none());
    }

    #[test]
    fn the_next_boundary_is_the_nearest_edge() {
        let s = schedule("22:00", "07:00");
        let next = next_boundary(&s, at(21, 0)).expect("a boundary");
        assert_eq!((next.hour(), next.minute()), (22, 0));

        let next = next_boundary(&s, at(23, 0)).expect("a boundary");
        assert_eq!((next.hour(), next.minute()), (7, 0));
        assert_eq!(next.day(), at(23, 0).day() + 1);

        // Exactly on a boundary, the next one is the other edge.
        let next = next_boundary(&s, at(22, 0)).expect("a boundary");
        assert_eq!((next.hour(), next.minute()), (7, 0));
    }
}
