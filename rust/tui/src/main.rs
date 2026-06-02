mod animation;
mod images;
mod input;
mod protocol;
mod renderer;
mod semantic;
mod signals;
mod terminal;

use mio::unix::SourceFd;
use mio::{Events, Interest, Poll, Token};
use std::io::{self, Read, Write};
use std::os::fd::RawFd;
use std::time::Duration;

const STDIN_TOKEN: Token = Token(0);
const TTY_TOKEN: Token = Token(1);

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
    let image_support = images::ImageSupport::default();
    protocol::write_packet(
        &mut stdout,
        &protocol::encode_ready_with_caps(cols, rows, image_support.capability_code()),
    )?;

    log_info(&mut stdout, &format!("started size={cols}x{rows}"));

    let mut renderer = renderer::Renderer::new(cols, rows);
    let mut stdin = io::stdin().lock();
    let mut input = input::Parser::default();
    let mut tty_read_buf = [0_u8; 4096];
    let resize_signal = signals::ResizeSignal::install().ok();
    let mut input_poll = match terminal.fd() {
        Some(tty_fd) => Some(InputPoll::new(libc::STDIN_FILENO, tty_fd)?),
        None => None,
    };

    loop {
        if terminal.fd().is_none() {
            match read_packet(&mut stdin)? {
                Some(packet) => handle_packet(&packet, &mut renderer, &mut terminal, &mut stdout)?,
                None => break,
            }
            continue;
        };

        let ready = input_poll
            .as_mut()
            .expect("terminal fd implies input poll")
            .poll(Duration::from_millis(100))?;

        if resize_signal
            .as_ref()
            .is_some_and(signals::ResizeSignal::take)
        {
            publish_resize(&mut terminal, &mut renderer, &mut stdout)?;
        } else if let Some((width, height)) = terminal.poll_size()? {
            renderer.resize(width, height);
            protocol::write_packet(&mut stdout, &protocol::encode_resize(width, height))?;
        }

        if !ready.any() {
            for event in input.flush_escape() {
                write_input_event(event, &mut stdout)?;
            }
            continue;
        }

        if ready.stdin {
            match read_packet(&mut stdin)? {
                Some(packet) => handle_packet(&packet, &mut renderer, &mut terminal, &mut stdout)?,
                None => break,
            }
        }

        if ready.tty {
            let read = terminal.read_input(&mut tty_read_buf)?;
            if read == 0 {
                break;
            }
            for event in input.push(&tty_read_buf[..read]) {
                write_input_event(event, &mut stdout)?;
            }
        }

        if ready.disconnected {
            break;
        }
    }

    terminal.finish()
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
struct InputReady {
    stdin: bool,
    tty: bool,
    disconnected: bool,
}

impl InputReady {
    fn any(self) -> bool {
        self.stdin || self.tty || self.disconnected
    }
}

struct InputPoll {
    poll: Poll,
    events: Events,
}

impl InputPoll {
    fn new(stdin_fd: RawFd, tty_fd: RawFd) -> io::Result<Self> {
        let poll = Poll::new()?;
        let mut stdin_source = SourceFd(&stdin_fd);
        let mut tty_source = SourceFd(&tty_fd);

        poll.registry()
            .register(&mut stdin_source, STDIN_TOKEN, Interest::READABLE)?;
        poll.registry()
            .register(&mut tty_source, TTY_TOKEN, Interest::READABLE)?;

        Ok(Self {
            poll,
            events: Events::with_capacity(16),
        })
    }

    fn poll(&mut self, timeout: Duration) -> io::Result<InputReady> {
        loop {
            match self.poll.poll(&mut self.events, Some(timeout)) {
                Ok(()) => break,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
        }

        let mut ready = InputReady::default();
        for event in self.events.iter() {
            match event.token() {
                STDIN_TOKEN => {
                    ready.stdin |= event.is_readable();
                    ready.disconnected |= event.is_read_closed() || event.is_error();
                }
                TTY_TOKEN => {
                    ready.tty |= event.is_readable();
                    ready.disconnected |= event.is_read_closed() || event.is_error();
                }
                _ => {}
            }
        }
        Ok(ready)
    }
}

fn publish_resize(
    terminal: &mut terminal::Terminal,
    renderer: &mut renderer::Renderer,
    output: &mut impl Write,
) -> io::Result<()> {
    if let Some((width, height)) = terminal.poll_size()? {
        let _timer = animation::RESIZE_SETTLE.timer();
        renderer.resize(width, height);
        protocol::write_packet(output, &protocol::encode_resize(width, height))?;
    }
    Ok(())
}

fn handle_packet(
    packet: &[u8],
    renderer: &mut renderer::Renderer,
    terminal: &mut terminal::Terminal,
    output: &mut impl Write,
) -> io::Result<()> {
    let mut offset = 0;

    while offset < packet.len() {
        let command_size = match protocol::command_byte_size(&packet[offset..]) {
            Ok(size) => size,
            Err(error) => {
                log_warn(
                    output,
                    &format!("protocol size error at {offset}: {error}"),
                );
                break;
            }
        };

        let command = match protocol::decode_command(&packet[offset..]) {
            Ok(command) => command,
            Err(error) => {
                log_warn(
                    output,
                    &format!("protocol decode error at {offset}: {error}"),
                );
                break;
            }
        };

        offset += command_size;

        if let Err(error) = renderer.handle(command, terminal, output) {
            log_warn(output, &format!("render error: {error}"));
        }
    }

    Ok(())
}

fn log_info(output: &mut impl Write, msg: &str) {
    let _ = protocol::write_packet(
        output,
        &protocol::encode_log_message(protocol::LOG_LEVEL_INFO, msg),
    );
}

fn log_warn(output: &mut impl Write, msg: &str) {
    let _ = protocol::write_packet(
        output,
        &protocol::encode_log_message(protocol::LOG_LEVEL_WARN, msg),
    );
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
