use anyhow::{Result, ensure};
use std::{
    cell::Cell,
    time::{Duration, Instant},
};
thread_local! { static END: Cell<Option<Instant>> = const { Cell::new(None) }; }
pub fn with_deadline<T>(duration: Duration, work: impl FnOnce() -> T) -> T {
    struct Restore(Option<Instant>);
    impl Drop for Restore {
        fn drop(&mut self) {
            END.set(self.0);
        }
    }
    let previous = END.get();
    let end = Instant::now() + duration;
    END.set(Some(previous.map_or(end, |old| old.min(end))));
    let _restore = Restore(previous);
    work()
}
pub fn check_deadline() -> Result<()> {
    budget(Duration::from_secs(120)).map(|_| ())
}
/// Reserve time before a side effect. Once started, a write owns its bounded
/// lifetime instead of inheriting a nearly exhausted presentation deadline.
pub(super) fn write_budget<T>(work: impl FnOnce() -> Result<T>) -> Result<T> {
    reserved_write_budget(Duration::from_secs(10), work)
}
fn reserved_write_budget<T>(minimum: Duration, work: impl FnOnce() -> Result<T>) -> Result<T> {
    ensure!(budget(Duration::from_secs(120))? >= minimum, "git_timeout");
    fresh_deadline(Duration::from_secs(120), work)
}
pub fn fresh_deadline<T>(duration: Duration, work: impl FnOnce() -> T) -> T {
    let previous = END.replace(None);
    struct Restore(Option<Instant>);
    impl Drop for Restore {
        fn drop(&mut self) {
            END.set(self.0);
        }
    }
    let _restore = Restore(previous);
    with_deadline(duration, work)
}
pub(super) fn budget(maximum: Duration) -> Result<Duration> {
    if let Some(end) = END.get() {
        let remaining = end.saturating_duration_since(Instant::now());
        ensure!(!remaining.is_zero(), "git_timeout");
        Ok(maximum.min(remaining))
    } else {
        Ok(maximum)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn write_is_rejected_before_start_or_keeps_its_own_budget() {
        let started = Cell::new(false);
        let rejected = with_deadline(Duration::from_millis(20), || {
            write_budget(|| {
                started.set(true);
                Ok(())
            })
        });
        assert_eq!(rejected.unwrap_err().to_string(), "git_timeout");
        assert!(!started.get());
        with_deadline(Duration::from_millis(100), || {
            reserved_write_budget(Duration::from_millis(50), || {
                std::thread::sleep(Duration::from_millis(150));
                assert!(budget(Duration::from_secs(120))? > Duration::from_secs(100));
                Ok(())
            })
            .unwrap();
            assert_eq!(check_deadline().unwrap_err().to_string(), "git_timeout");
        });
        check_deadline().unwrap();
    }
}
