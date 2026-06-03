mod animation;
mod images;
mod input;
mod protocol;
mod renderer;
mod semantic;
mod signals;
mod terminal;

use crossterm::event;
use std::io::{self, Read, Write};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::thread;
use std::time::Duration;

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
    let resize_signal = signals::ResizeSignal::install().ok();
    let (events_tx, events_rx) = mpsc::channel();
    spawn_packet_reader(events_tx.clone());
    spawn_input_reader(events_tx);

    loop {
        if resize_signal
            .as_ref()
            .is_some_and(signals::ResizeSignal::take)
        {
            publish_resize(&mut terminal, &mut renderer, &mut stdout)?;
        }

        match events_rx.recv_timeout(Duration::from_millis(100)) {
            Ok(LoopEvent::Packet(packet)) => {
                handle_packet(&packet, &mut renderer, &mut terminal, &mut stdout)?;
            }
            Ok(LoopEvent::Input(event)) => {
                handle_input_event(event, &mut terminal, &mut renderer, &mut stdout)?;
            }
            Ok(LoopEvent::BackendClosed) => break,
            Err(RecvTimeoutError::Timeout) => {
                if let Some((width, height)) = terminal.poll_size()? {
                    renderer.resize(width, height);
                    protocol::write_packet(&mut stdout, &protocol::encode_resize(width, height))?;
                }
            }
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }

    terminal.finish()
}

#[derive(Debug)]
enum LoopEvent {
    Packet(Vec<u8>),
    Input(input::Event),
    BackendClosed,
}

fn spawn_packet_reader(events_tx: Sender<LoopEvent>) {
    thread::spawn(move || {
        let mut stdin = io::stdin().lock();
        loop {
            match read_packet(&mut stdin) {
                Ok(Some(packet)) => {
                    if events_tx.send(LoopEvent::Packet(packet)).is_err() {
                        break;
                    }
                }
                Ok(None) => {
                    let _ = events_tx.send(LoopEvent::BackendClosed);
                    break;
                }
                Err(_) => {
                    let _ = events_tx.send(LoopEvent::BackendClosed);
                    break;
                }
            }
        }
    });
}

fn spawn_input_reader(events_tx: Sender<LoopEvent>) {
    thread::spawn(move || {
        while let Ok(event) = event::read() {
            if let Some(event) = input::map_crossterm_event(event)
                && events_tx.send(LoopEvent::Input(event)).is_err()
            {
                break;
            }
        }
    });
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

fn handle_input_event(
    event: input::Event,
    terminal: &mut terminal::Terminal,
    renderer: &mut renderer::Renderer,
    output: &mut impl Write,
) -> io::Result<()> {
    match event {
        input::Event::Resize { cols, rows } => {
            renderer.resize(cols, rows);
            protocol::write_packet(output, &protocol::encode_resize(cols, rows))?;
            if let Some((width, height)) = terminal.poll_size()? {
                renderer.resize(width, height);
            }
            Ok(())
        }
        input::Event::Key { .. } | input::Event::Paste(_) => write_input_event(event, output),
    }
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
                log_warn(output, &format!("protocol size error at {offset}: {error}"));
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
        input::Event::Resize { .. } => Ok(()),
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
