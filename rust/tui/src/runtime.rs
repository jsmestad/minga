use crate::parity::FramePolicy;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DrainDecision {
    Wait(Duration),
    Render,
}

#[derive(Debug, Clone, Copy)]
pub struct FrameRuntime {
    policy: FramePolicy,
}

impl FrameRuntime {
    pub fn new(policy: FramePolicy) -> Self {
        Self { policy }
    }

    pub fn coalescing_deadline(&self, now: Instant) -> Option<Instant> {
        if self.policy.packet_coalesce_us == 0 {
            None
        } else {
            Some(now + Duration::from_micros(self.policy.packet_coalesce_us))
        }
    }

    pub fn drain_decision(&self, now: Instant, deadline: Instant) -> DrainDecision {
        if now >= deadline {
            DrainDecision::Render
        } else {
            DrainDecision::Wait(deadline - now)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_coalescing_policy_renders_immediately() {
        let runtime = FrameRuntime::new(FramePolicy {
            packet_coalesce_us: 0,
        });

        assert!(runtime.coalescing_deadline(Instant::now()).is_none());
    }

    #[test]
    fn coalescing_policy_waits_until_deadline_then_renders() {
        let runtime = FrameRuntime::new(FramePolicy {
            packet_coalesce_us: 1_000,
        });
        let now = Instant::now();
        let deadline = runtime.coalescing_deadline(now).unwrap();

        assert_eq!(
            runtime.drain_decision(now, deadline),
            DrainDecision::Wait(Duration::from_micros(1_000))
        );
        assert_eq!(
            runtime.drain_decision(deadline, deadline),
            DrainDecision::Render
        );
    }
}
