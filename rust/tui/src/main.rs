mod animation;
mod app;
mod beam_host;
mod images;
mod input;
mod parity;
mod protocol;
mod render_scheduler;
mod runtime;
mod semantic;
mod semantic_renderer;
mod semantic_state;
mod signals;
mod telemetry;
mod terminal;

use std::io::{self, Write};

fn main() {
    let _trace_guard = telemetry::init();

    if let Err(error) = app::run() {
        let _ = writeln!(io::stderr(), "[RUST_TUI/error] {error}");
        std::process::exit(1);
    }
}
