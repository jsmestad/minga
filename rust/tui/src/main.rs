mod protocol;
mod renderer;
mod terminal;

use std::io::{self, Read, Write};

fn main() {
    if let Err(error) = run() {
        let _ = writeln!(io::stderr(), "[RUST_TUI/error] {error}");
        std::process::exit(1);
    }
}

fn run() -> io::Result<()> {
    let mut terminal = terminal::Terminal::open()?;
    let (cols, rows) = terminal.size();
    protocol::write_packet(
        &mut io::stdout().lock(),
        &protocol::encode_ready_with_caps(cols, rows),
    )?;

    let mut renderer = renderer::Renderer::new(cols, rows);
    let mut stdin = io::stdin().lock();

    while let Some(packet) = read_packet(&mut stdin)? {
        let mut offset = 0;

        while offset < packet.len() {
            let command = match protocol::decode_command(&packet[offset..]) {
                Ok(command) => command,
                Err(error) => {
                    let _ = writeln!(
                        io::stderr(),
                        "[RUST_TUI/warn] protocol decode error at {offset}: {error}"
                    );
                    break;
                }
            };

            offset += command.size();

            if let Err(error) = renderer.handle(command, &mut terminal) {
                let _ = writeln!(io::stderr(), "[RUST_TUI/warn] render error: {error}");
            }
        }
    }

    terminal.finish()
}

fn read_packet(reader: &mut impl Read) -> io::Result<Option<Vec<u8>>> {
    let mut len = [0_u8; 4];

    match reader.read_exact(&mut len) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(error),
    }

    let len = u32::from_be_bytes(len) as usize;
    let mut payload = vec![0_u8; len];
    reader.read_exact(&mut payload)?;
    Ok(Some(payload))
}
