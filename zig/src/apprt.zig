/// AppRuntime — backend selection and dispatch.
///
/// The backend is selected at build time via `-Dbackend=tui` (default).
/// Each backend implements init/run/deinit and provides a Surface type
/// for the generic Renderer.
const build_options = @import("build_options");

pub const Backend = switch (build_options.backend) {
    .tui => @import("apprt/tui.zig"),
    // Future: .gui => @import("apprt/gui.zig"),
};

test {
    _ = Backend;
}
