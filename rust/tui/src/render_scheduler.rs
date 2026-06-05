use crate::semantic_state::DirtyKind;
use std::time::Instant;

#[derive(Debug)]
pub struct RenderScheduler {
    pending: bool,
    dirty: DirtyKind,
    request_count: u64,
    first_requested_at: Option<Instant>,
}

impl Default for RenderScheduler {
    fn default() -> Self {
        Self {
            pending: false,
            dirty: DirtyKind::Full,
            request_count: 0,
            first_requested_at: None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RenderBatch {
    pub request_count: u64,
    pub pending_us: u128,
    pub dirty: DirtyKind,
}

impl RenderScheduler {
    pub fn request(&mut self) {
        if !self.pending {
            self.first_requested_at = Some(Instant::now());
            self.dirty = DirtyKind::Full;
        } else {
            self.dirty = DirtyKind::Full;
        }
        self.pending = true;
        self.request_count = self.request_count.saturating_add(1);
    }

    pub fn request_partial(&mut self) {
        if !self.pending {
            self.first_requested_at = Some(Instant::now());
            self.dirty = DirtyKind::Partial;
        }
        // If already pending and Full, keep Full
        self.pending = true;
        self.request_count = self.request_count.saturating_add(1);
    }

    pub fn pending(&self) -> bool {
        self.pending
    }

    pub fn take_ready(&mut self) -> Option<RenderBatch> {
        if !self.pending {
            return None;
        }

        let batch = RenderBatch {
            request_count: self.request_count,
            pending_us: self
                .first_requested_at
                .map(|requested_at| requested_at.elapsed().as_micros())
                .unwrap_or(0),
            dirty: self.dirty,
        };
        self.pending = false;
        self.request_count = 0;
        self.first_requested_at = None;
        self.dirty = DirtyKind::Full;
        Some(batch)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn coalesces_multiple_render_requests_into_one_batch() {
        let mut scheduler = RenderScheduler::default();

        scheduler.request();
        scheduler.request();

        assert!(scheduler.pending());

        let batch = scheduler.take_ready().unwrap();
        assert_eq!(batch.request_count, 2);
        assert_eq!(batch.dirty, DirtyKind::Full);
        assert!(scheduler.take_ready().is_none());
    }

    #[test]
    fn partial_requests_stay_partial_when_all_partial() {
        let mut scheduler = RenderScheduler::default();

        scheduler.request_partial();
        scheduler.request_partial();

        let batch = scheduler.take_ready().unwrap();
        assert_eq!(batch.dirty, DirtyKind::Partial);
    }

    #[test]
    fn full_request_escalates_partial_to_full() {
        let mut scheduler = RenderScheduler::default();

        scheduler.request_partial();
        scheduler.request();

        let batch = scheduler.take_ready().unwrap();
        assert_eq!(batch.dirty, DirtyKind::Full);
    }

    #[test]
    fn partial_after_full_stays_full() {
        let mut scheduler = RenderScheduler::default();

        scheduler.request();
        scheduler.request_partial();

        let batch = scheduler.take_ready().unwrap();
        assert_eq!(batch.dirty, DirtyKind::Full);
    }
}
