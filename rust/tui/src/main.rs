mod animation;
mod app;
mod beam_host;
mod images;
mod input;
mod protocol;
mod renderer;
mod semantic;
mod semantic_renderer;
mod semantic_state;
mod signals;
mod terminal;

use std::io::{self, Write};

fn main() {
    if let Err(error) = app::run() {
        let _ = writeln!(io::stderr(), "[RUST_TUI/error] {error}");
        std::process::exit(1);
    }
}
