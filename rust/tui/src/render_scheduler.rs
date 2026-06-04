use std::time::Instant;

#[derive(Debug, Default)]
pub struct RenderScheduler {
    pending: bool,
    request_count: u64,
    first_requested_at: Option<Instant>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RenderBatch {
    pub request_count: u64,
    pub pending_us: u128,
}

impl RenderScheduler {
    pub fn request(&mut self) {
        if !self.pending {
            self.first_requested_at = Some(Instant::now());
        }
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
        };
        self.pending = false;
        self.request_count = 0;
        self.first_requested_at = None;
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
        assert!(scheduler.take_ready().is_none());
    }
}
