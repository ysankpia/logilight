//! Smooth scrolling.
//!
//! One `CGEventTap` watches mouse wheel events and one emitter thread replays
//! each gesture in small steps, so a page glides instead of jumping a notch.
//!
//! Safety rules, learned the hard way (a stuck tap left the wheel dead until the
//! owning app was restarted):
//!
//! * the tap passes every event through unless smoothing is switched on, so a
//!   disabled tap costs nothing and cannot swallow a gesture;
//! * a tap the system disabled is re-enabled on the next run-loop turn;
//! * the events this module posts carry [`TAG`] and are passed through, so the
//!   tap can never feed itself;
//! * when a post fails, smoothing switches itself off instead of holding the
//!   gesture hostage.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::Duration;

use anyhow::{Result, anyhow};
use core_foundation::runloop::CFRunLoop;
use core_foundation_sys::runloop::{kCFRunLoopCommonModes, kCFRunLoopDefaultMode};
use core_graphics::event::{
    CGEvent, CGEventTap, CGEventTapLocation, CGEventTapOptions, CGEventTapPlacement, CGEventType,
    CallbackResult, EventField, ScrollEventUnit,
};
use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};

/// Marks the events this module posts, so its own tap passes them through.
const TAG: i64 = 0x4c47_4c54;

/// Emitter cadence: 125 Hz, the rate a scroll gesture reads as smooth at.
const TICK: Duration = Duration::from_millis(8);

/// A wheel notch reports lines rather than points; this is the usual ratio.
const LINES_TO_POINTS: f64 = 10.0;

/// Below one point there is nothing left worth posting.
const IDLE_POINTS: f64 = 1.0;

/// Two axes of pending travel, in points.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
struct Delta {
    x: f64,
    y: f64,
}

impl Delta {
    fn is_zero(self) -> bool {
        self.x == 0.0 && self.y == 0.0
    }

    fn scaled(self, factor: f64) -> Self {
        Self {
            x: self.x * factor,
            y: self.y * factor,
        }
    }

    fn is_below_idle(self) -> bool {
        self.x.abs() < IDLE_POINTS && self.y.abs() < IDLE_POINTS
    }
}

/// State shared by the tap, the emitter and the control channel.
pub struct Shared {
    enabled: AtomicBool,
    duration_ms: AtomicU64,
    pending: Mutex<Delta>,
    /// Gestures intercepted since the daemon started (diagnostics).
    intercepted: AtomicU64,
    /// Events posted since the daemon started (diagnostics).
    emitted: AtomicU64,
    /// Set when the system disabled the tap and it must be re-enabled.
    reenable: AtomicBool,
    /// Every callback invocation (diagnostics).
    seen: AtomicU64,
}

static INSTANCE: OnceLock<Arc<Shared>> = OnceLock::new();

impl Shared {
    /// Switch smoothing on or off. Off means the tap passes everything through.
    pub fn set_enabled(&self, enabled: bool) {
        self.enabled.store(enabled, Ordering::Relaxed);
        if !enabled {
            self.pending
                .lock()
                .map(|mut pending| *pending = Delta::default())
                .ok();
        }
    }

    #[must_use]
    pub fn enabled(&self) -> bool {
        self.enabled.load(Ordering::Relaxed)
    }

    pub fn set_duration_ms(&self, duration_ms: u64) {
        self.duration_ms
            .store(duration_ms.clamp(60, 2_000), Ordering::Relaxed);
    }

    #[must_use]
    pub fn duration_ms(&self) -> u64 {
        self.duration_ms.load(Ordering::Relaxed)
    }

    #[must_use]
    pub fn counters(&self) -> (u64, u64) {
        (
            self.intercepted.load(Ordering::Relaxed),
            self.emitted.load(Ordering::Relaxed),
        )
    }
}

/// Start the tap and its emitter. Idempotent: a second call returns the first.
pub fn start(enabled: bool, duration_ms: u64) -> Result<Arc<Shared>> {
    if let Some(shared) = INSTANCE.get() {
        return Ok(Arc::clone(shared));
    }
    // Without the grant the tap cannot be created, and a state that says "on"
    // with no tap would be a lie: refuse instead of pretending.
    if !has_accessibility() {
        return Err(anyhow!(
            "smooth scrolling needs Accessibility — System Settings → Privacy & Security → \
             Accessibility, then restart the agent"
        ));
    }
    let shared = Arc::new(Shared {
        enabled: AtomicBool::new(enabled),
        duration_ms: AtomicU64::new(duration_ms.clamp(60, 2_000)),
        pending: Mutex::new(Delta::default()),
        intercepted: AtomicU64::new(0),
        emitted: AtomicU64::new(0),
        reenable: AtomicBool::new(false),
        seen: AtomicU64::new(0),
    });

    let tap_state = Arc::clone(&shared);
    thread::Builder::new()
        .name("logilight-scroll-tap".into())
        .spawn(move || {
            if let Err(error) = run_tap(&tap_state) {
                eprintln!("smooth: {error:#}");
            }
        })?;

    let emitter_state = Arc::clone(&shared);
    thread::Builder::new()
        .name("logilight-scroll-emit".into())
        .spawn(move || emit_loop(&emitter_state))?;

    let _ = INSTANCE.set(Arc::clone(&shared));
    Ok(shared)
}

/// The daemon's single smoothing instance, when [`start`] has run.
#[must_use]
pub fn instance() -> Option<&'static Arc<Shared>> {
    INSTANCE.get()
}

/// Whether this process may install a suppressing event tap.
#[must_use]
pub fn has_accessibility() -> bool {
    #[link(name = "ApplicationServices", kind = "framework")]
    unsafe extern "C" {
        fn AXIsProcessTrusted() -> bool;
    }
    // SAFETY: the call has no arguments and no ownership to reason about.
    unsafe { AXIsProcessTrusted() }
}

fn run_tap(shared: &Arc<Shared>) -> Result<()> {
    let state = Arc::clone(shared);
    let tap = CGEventTap::new(
        CGEventTapLocation::HID,
        CGEventTapPlacement::TailAppendEventTap,
        CGEventTapOptions::Default,
        // Only real event types belong in the mask: the two TapDisabled
        // notifications are delivered without being requested, and their huge
        // type values overflow the mask shift.
        vec![CGEventType::ScrollWheel],
        move |_proxy, event_type, event| handle(&state, event_type, event),
    )
    .map_err(|()| {
        anyhow!(
            "could not create the scroll event tap — grant Accessibility to LogiLight \
             (System Settings → Privacy & Security → Accessibility)"
        )
    })?;
    tap.enable();
    // The tap is inert until its mach port has a run-loop source: `CGEventTap`
    // only creates the port, it does not schedule it.
    let source = tap
        .mach_port()
        .create_runloop_source(0)
        .map_err(|()| anyhow!("could not create the tap's run-loop source"))?;
    CFRunLoop::get_current().add_source(&source, unsafe { kCFRunLoopCommonModes });
    loop {
        // A bounded run-loop turn lets the tap be re-enabled from this thread;
        // `run_current` would never come back.
        // SAFETY: the constant is a process-wide CFString owned by the system.
        let mode = unsafe { kCFRunLoopDefaultMode };
        CFRunLoop::run_in_mode(mode, Duration::from_millis(50), false);
        if shared.reenable.swap(false, Ordering::Relaxed) {
            tap.enable();
        }
    }
}

fn handle(shared: &Shared, event_type: CGEventType, event: &CGEvent) -> CallbackResult {
    shared.seen.fetch_add(1, Ordering::Relaxed);
    match event_type {
        CGEventType::TapDisabledByTimeout | CGEventType::TapDisabledByUserInput => {
            shared.reenable.store(true, Ordering::Relaxed);
            return CallbackResult::Keep;
        }
        CGEventType::ScrollWheel => {}
        _ => return CallbackResult::Keep,
    }
    if !shared.enabled.load(Ordering::Relaxed) {
        return CallbackResult::Keep;
    }
    if event.get_integer_value_field(EventField::EVENT_SOURCE_USER_DATA) == TAG {
        return CallbackResult::Keep;
    }
    // Trackpad gestures and their momentum already arrive smooth.
    if event.get_integer_value_field(EventField::SCROLL_WHEEL_EVENT_IS_CONTINUOUS) != 0 {
        return CallbackResult::Keep;
    }
    let delta = Delta {
        x: points(
            event,
            EventField::SCROLL_WHEEL_EVENT_FIXED_POINT_DELTA_AXIS_2,
            EventField::SCROLL_WHEEL_EVENT_DELTA_AXIS_2,
        ),
        y: points(
            event,
            EventField::SCROLL_WHEEL_EVENT_FIXED_POINT_DELTA_AXIS_1,
            EventField::SCROLL_WHEEL_EVENT_DELTA_AXIS_1,
        ),
    };
    if delta.is_zero() {
        return CallbackResult::Keep;
    }
    if let Ok(mut pending) = shared.pending.lock() {
        pending.x += delta.x;
        pending.y += delta.y;
    } else {
        return CallbackResult::Keep;
    }
    shared.intercepted.fetch_add(1, Ordering::Relaxed);
    CallbackResult::Drop
}

/// One axis of a wheel event in points: the fixed-point field when the device
/// reports it, the line count otherwise.
fn points(event: &CGEvent, fixed: u32, lines: u32) -> f64 {
    let fixed = event.get_integer_value_field(fixed) as f64 / 65536.0;
    if fixed != 0.0 {
        fixed
    } else {
        event.get_integer_value_field(lines) as f64 * LINES_TO_POINTS
    }
}

fn emit_loop(shared: &Arc<Shared>) {
    let source = CGEventSource::new(CGEventSourceStateID::HIDSystemState).ok();
    // Time since the last point went out: a gesture that has shrunk below one
    // point per tick keeps accumulating time until a whole point fits, instead
    // of waiting forever on a fraction it can never post.
    let mut since_emit = Duration::ZERO;
    loop {
        thread::sleep(TICK);
        since_emit += TICK;
        let duration = Duration::from_millis(shared.duration_ms.load(Ordering::Relaxed));
        let fraction = step_fraction(since_emit, duration);
        let pending = match shared.pending.lock() {
            Ok(pending) => *pending,
            Err(_) => return,
        };
        if pending.is_zero() {
            since_emit = Duration::ZERO;
            continue;
        }
        let (emit, rest) = next_step(pending, fraction);
        if let Ok(mut guard) = shared.pending.lock() {
            *guard = rest;
        }
        if emit.is_zero() {
            continue;
        }
        since_emit = Duration::ZERO;
        match post(source.as_ref(), emit) {
            Ok(()) => {
                shared.emitted.fetch_add(1, Ordering::Relaxed);
            }
            Err(error) => {
                eprintln!("smooth: {error:#} — switching smoothing off");
                shared.set_enabled(false);
            }
        }
    }
}

/// The share of the remaining travel one tick should deliver.
///
/// Exponential with a time constant of a quarter of the chosen duration, so
/// about 98% of a gesture has arrived by the time that duration is up.
fn step_fraction(tick: Duration, duration: Duration) -> f64 {
    let tau = (duration.as_secs_f64() / 4.0).max(0.001);
    1.0 - (-(tick.as_secs_f64() / tau)).exp()
}

/// Split one tick's travel into whole points to post now and the rest to keep.
///
/// Whole points only: a fractional step would be rounded away, so the leftover
/// stays pending and a slow gesture loses nothing. Once the remainder is below
/// a point, it is posted too and the queue goes idle.
fn next_step(pending: Delta, fraction: f64) -> (Delta, Delta) {
    let step = pending.scaled(fraction);
    let emit = Delta {
        x: step.x.trunc(),
        y: step.y.trunc(),
    };
    let rest = Delta {
        x: pending.x - emit.x,
        y: pending.y - emit.y,
    };
    if rest.is_below_idle() {
        let flushed = Delta {
            x: emit.x + rest.x.round(),
            y: emit.y + rest.y.round(),
        };
        return (flushed, Delta::default());
    }
    (emit, rest)
}

fn post(source: Option<&CGEventSource>, delta: Delta) -> Result<()> {
    let source = source.ok_or_else(|| anyhow!("no HID event source"))?;
    let event = CGEvent::new_scroll_event(
        source.clone(),
        ScrollEventUnit::PIXEL,
        2,
        delta.y.round() as i32,
        delta.x.round() as i32,
        0,
    )
    .map_err(|()| anyhow!("could not create a scroll event"))?;
    event.set_integer_value_field(EventField::EVENT_SOURCE_USER_DATA, TAG);
    event.post(CGEventTapLocation::HID);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{Delta, next_step, step_fraction};
    use std::time::Duration;

    fn delta(x: f64, y: f64) -> Delta {
        Delta { x, y }
    }

    #[test]
    fn one_tick_moves_a_fraction_of_the_remaining_travel() {
        let fraction = step_fraction(Duration::from_millis(8), Duration::from_millis(300));
        assert!(fraction > 0.05 && fraction < 0.2, "{fraction}");

        let (emit, rest) = next_step(delta(0.0, 30.0), fraction);
        assert!(emit.y >= 1.0 && emit.y <= 4.0, "{}", emit.y);
        assert!((emit.y + rest.y - 30.0).abs() < f64::EPSILON);
    }

    #[test]
    fn a_long_gesture_keeps_what_rounding_would_have_lost() {
        let duration = Duration::from_millis(300);
        let mut pending = delta(0.0, 30.0);
        let mut since_emit = Duration::ZERO;
        let mut posted = 0.0;
        for _ in 0..500 {
            since_emit += Duration::from_millis(8);
            let (emit, rest) = next_step(pending, step_fraction(since_emit, duration));
            posted += emit.y;
            pending = rest;
            if !emit.is_zero() {
                since_emit = Duration::ZERO;
            }
            if pending.is_zero() {
                break;
            }
        }
        assert!(pending.is_zero(), "queue never drained: {pending:?}");
        assert!((posted - 30.0).abs() < 1.0, "posted {posted}");
    }

    #[test]
    fn a_tiny_remainder_is_flushed_instead_of_lingering() {
        let (emit, rest) = next_step(delta(0.4, -0.6), 0.1);
        assert_eq!(rest, Delta::default());
        assert_eq!(emit, delta(0.0, -1.0));
    }

    #[test]
    fn a_bigger_tick_delivers_more() {
        let slow = step_fraction(Duration::from_millis(8), Duration::from_millis(600));
        let fast = step_fraction(Duration::from_millis(8), Duration::from_millis(120));
        assert!(fast > slow);
    }

    /// End to end through the real event tap. Needs Accessibility, which CI does
    /// not have, so it is ignored by default:
    ///
    /// ```sh
    /// cargo test -- --ignored smooth_tap
    /// ```
    #[test]
    #[ignore = "needs Accessibility for an event tap"]
    fn the_tap_swallows_a_wheel_notch_and_posts_it_in_steps() {
        use core_graphics::event::{CGEvent, CGEventTapLocation, ScrollEventUnit};
        use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};

        if !super::has_accessibility() {
            eprintln!("no Accessibility — nothing to test");
            return;
        }
        let shared = super::start(true, 200).expect("start smoothing");
        std::thread::sleep(Duration::from_millis(400));

        let source = CGEventSource::new(CGEventSourceStateID::HIDSystemState).expect("source");
        let notch = CGEvent::new_scroll_event(source, ScrollEventUnit::LINE, 2, -3, 0, 0)
            .expect("scroll event");
        notch.post(CGEventTapLocation::HID);
        std::thread::sleep(Duration::from_millis(800));

        let (intercepted, emitted) = shared.counters();
        let seen = shared.seen.load(std::sync::atomic::Ordering::Relaxed);
        shared.set_enabled(false);
        assert!(seen >= 1, "the callback never ran");
        assert!(
            intercepted >= 1,
            "the tap saw {seen} event(s) but not the notch"
        );
        assert!(emitted >= 2, "the notch was posted in {emitted} step(s)");
    }
}
