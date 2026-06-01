mod input;
mod protocol;
mod renderer;
mod semantic;
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
    let mut stdout = io::stdout().lock();
    protocol::write_packet(&mut stdout, &protocol::encode_ready_with_caps(cols, rows))?;

    let mut renderer = renderer::Renderer::new(cols, rows);
    let mut stdin = io::stdin().lock();
    let mut input = input::Parser::default();
    let mut tty_read_buf = [0_u8; 4096];

    loop {
        let Some(tty_fd) = terminal.fd() else {
            match read_packet(&mut stdin)? {
                Some(packet) => handle_packet(&packet, &mut renderer, &mut terminal, &mut stdout)?,
                None => break,
            }
            continue;
        };

        let mut pollfds = [
            libc::pollfd {
                fd: libc::STDIN_FILENO,
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: tty_fd,
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        let poll_result =
            unsafe { libc::poll(pollfds.as_mut_ptr(), pollfds.len() as libc::nfds_t, 100) };

        if poll_result < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }

        if let Some((width, height)) = terminal.poll_size()? {
            renderer.resize(width, height);
            protocol::write_packet(&mut stdout, &protocol::encode_resize(width, height))?;
        }

        if poll_result == 0 {
            for event in input.flush_escape() {
                write_input_event(event, &mut stdout)?;
            }
            continue;
        }

        if pollfds[0].revents & libc::POLLIN != 0 {
            match read_packet(&mut stdin)? {
                Some(packet) => handle_packet(&packet, &mut renderer, &mut terminal, &mut stdout)?,
                None => break,
            }
        }

        if pollfds[1].revents & libc::POLLIN != 0 {
            let read = terminal.read_input(&mut tty_read_buf)?;
            if read == 0 {
                break;
            }
            for event in input.push(&tty_read_buf[..read]) {
                write_input_event(event, &mut stdout)?;
            }
        }

        let hup_mask = libc::POLLHUP | libc::POLLERR | libc::POLLNVAL;
        if pollfds[0].revents & hup_mask != 0 || pollfds[1].revents & hup_mask != 0 {
            break;
        }
    }

    terminal.finish()
}

fn handle_packet(
    packet: &[u8],
    renderer: &mut renderer::Renderer,
    terminal: &mut terminal::Terminal,
    output: &mut impl Write,
) -> io::Result<()> {
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

        if let Err(error) = renderer.handle(command, terminal, output) {
            let _ = writeln!(io::stderr(), "[RUST_TUI/warn] render error: {error}");
        }
    }

    Ok(())
}

fn write_input_event(event: input::Event, output: &mut impl Write) -> io::Result<()> {
    match event {
        input::Event::Key {
            codepoint,
            modifiers,
        } => protocol::write_packet(output, &protocol::encode_key_press(codepoint, modifiers)),
        input::Event::Paste(text) => {
            if text.is_empty() {
                Ok(())
            } else {
                protocol::write_packet(output, &protocol::encode_paste_event(&text))
            }
        }
    }
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
