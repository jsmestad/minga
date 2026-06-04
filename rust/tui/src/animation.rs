#![allow(dead_code)]

use tachyonfx::{Duration, EffectTimer, Interpolation};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MotionCurve {
    Standard,
    Emphasized,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AnimationSpec {
    pub duration: Duration,
    pub curve: MotionCurve,
}

impl AnimationSpec {
    pub const fn new(milliseconds: u32, curve: MotionCurve) -> Self {
        Self {
            duration: Duration::from_millis(milliseconds),
            curve,
        }
    }

    pub fn timer(self) -> EffectTimer {
        EffectTimer::new(self.duration, self.curve.interpolation())
    }
}

impl MotionCurve {
    pub fn interpolation(self) -> Interpolation {
        match self {
            Self::Standard => Interpolation::QuadOut,
            Self::Emphasized => Interpolation::CubicOut,
        }
    }
}

pub const POPUP_REVEAL: AnimationSpec = AnimationSpec::new(90, MotionCurve::Standard);
pub const RESIZE_SETTLE: AnimationSpec = AnimationSpec::new(120, MotionCurve::Emphasized);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn animation_specs_use_tachyonfx_timers() {
        assert_eq!(POPUP_REVEAL.duration, Duration::from_millis(90));
        assert_eq!(POPUP_REVEAL.curve.interpolation(), Interpolation::QuadOut);

        let mut timer = RESIZE_SETTLE.timer();
        assert_eq!(timer.process(Duration::from_millis(30)), None);
    }
}
