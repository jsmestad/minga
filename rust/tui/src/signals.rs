use std::io;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Debug, Clone)]
pub struct ResizeSignal {
    pending: Arc<AtomicBool>,
}

impl ResizeSignal {
    pub fn install() -> io::Result<Self> {
        let pending = Arc::new(AtomicBool::new(false));
        signal_hook::flag::register(signal_hook::consts::SIGWINCH, Arc::clone(&pending))?;
        Ok(Self { pending })
    }

    pub fn take(&self) -> bool {
        self.pending.swap(false, Ordering::AcqRel)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn take_clears_pending_resize_flag() {
        let signal = ResizeSignal {
            pending: Arc::new(AtomicBool::new(true)),
        };

        assert!(signal.take());
        assert!(!signal.take());
    }
}
