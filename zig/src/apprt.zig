/// AppRuntime — backend selection and dispatch.
///
/// The TUI backend is built by default. The macOS GUI is a separate
/// Swift app (macos/) that speaks the same Port protocol.
const build_options = @import("build_options");

const legacy_tui = @import("apprt/tui.zig");
const zigzag_tui = @import("apprt/zigzag_tui.zig");

pub const Backend = switch (build_options.backend) {
    .tui => struct {
        pub const TuiRuntime = zigzag_tui.TuiRuntime;
        pub const LegacyVaxisRuntime = legacy_tui.TuiRuntime;
    },
};

test {
    _ = Backend;
    _ = legacy_tui;
    _ = zigzag_tui;
}
