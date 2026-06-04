#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrontendParityPolicy {
    pub terminal: TerminalPolicy,
    pub input: InputPolicy,
    pub frame: FramePolicy,
    pub tracing: TracePolicy,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalPolicy {
    pub alternate_screen: bool,
    pub bracketed_paste: bool,
    pub mouse_capture: MouseCapturePolicy,
    pub synchronized_update: bool,
    pub hide_cursor_while_rendering: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseCapturePolicy {
    CellMotion,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InputPolicy {
    pub passive_mouse_motion: PassiveMouseMotionPolicy,
    pub semantic_clicks_before_raw_mouse: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PassiveMouseMotionPolicy {
    Drop,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FramePolicy {
    pub packet_coalesce_us: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TracePolicy {
    pub input_latency: bool,
    pub packet_latency: bool,
    pub render_latency: bool,
}

pub const GO_ZIG_PARITY: FrontendParityPolicy = FrontendParityPolicy {
    terminal: TerminalPolicy {
        alternate_screen: true,
        bracketed_paste: true,
        mouse_capture: MouseCapturePolicy::CellMotion,
        synchronized_update: true,
        hide_cursor_while_rendering: true,
    },
    input: InputPolicy {
        passive_mouse_motion: PassiveMouseMotionPolicy::Drop,
        semantic_clicks_before_raw_mouse: true,
    },
    frame: FramePolicy {
        packet_coalesce_us: 0,
    },
    tracing: TracePolicy {
        input_latency: true,
        packet_latency: true,
        render_latency: true,
    },
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn go_zig_parity_uses_cell_motion_semantics() {
        assert_eq!(
            GO_ZIG_PARITY.terminal.mouse_capture,
            MouseCapturePolicy::CellMotion
        );
        assert_eq!(
            GO_ZIG_PARITY.input.passive_mouse_motion,
            PassiveMouseMotionPolicy::Drop
        );
        assert!(GO_ZIG_PARITY.input.semantic_clicks_before_raw_mouse);
    }

    #[test]
    fn go_zig_parity_enables_latency_tracing_hooks() {
        assert!(GO_ZIG_PARITY.tracing.input_latency);
        assert!(GO_ZIG_PARITY.tracing.packet_latency);
        assert!(GO_ZIG_PARITY.tracing.render_latency);
    }

    #[test]
    fn go_zig_parity_does_not_delay_typing_frames_by_default() {
        assert_eq!(GO_ZIG_PARITY.frame.packet_coalesce_us, 0);
    }
}
