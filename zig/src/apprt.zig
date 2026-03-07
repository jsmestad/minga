/// AppRuntime — backend selection and dispatch.
///
/// The TUI backend is built by default. The macOS GUI is a separate
/// Swift app (macos/) that speaks the same Port protocol.
const build_options = @import("build_options");

pub const Backend = switch (build_options.backend) {
    .tui => @import("apprt/tui.zig"),
};

test {
    _ = Backend;
}
