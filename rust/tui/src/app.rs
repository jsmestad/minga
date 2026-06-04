use crate::animation;
use crate::beam_host::{self, FrontendCapabilities};
use crate::images;
use crate::input;
use crate::semantic_renderer::SemanticRenderer;
use crate::semantic_state::SemanticState;
use crate::signals;
use crate::terminal::Terminal;
use crossterm::event;
use std::env;
use std::io::{self, Write};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::thread;
use std::time::Duration;

#[derive(Debug)]
enum LoopEvent {
    Packet(Vec<u8>),
    Input(input::Event),
    BackendClosed,
}

pub fn run() -> io::Result<()> {
    let mut terminal = Terminal::open()?;
    let (cols, rows) = terminal.size();
    let cli_args = env::args().skip(1).collect::<Vec<_>>();
    let mut host = beam_host::open(cli_args)?;
    let image_support = images::ImageSupport::default();

    beam_host::send_ready(
        host.output(),
        FrontendCapabilities {
            width: cols,
            height: rows,
            image_support: image_support.capability_code(),
        },
    )?;
    beam_host::log_info(
        host.output(),
        &format!("started semantic rust tui size={cols}x{rows}"),
    );

    let mut state = SemanticState::new(cols, rows);
    let mut renderer = SemanticRenderer::new();
    let resize_signal = signals::ResizeSignal::install().ok();
    let (events_tx, events_rx) = mpsc::channel();
    spawn_packet_reader(host.take_reader()?, events_tx.clone());
    spawn_input_reader(events_tx);
    let mut backend_closed = false;

    loop {
        if resize_signal
            .as_ref()
            .is_some_and(signals::ResizeSignal::take)
        {
            publish_resize(&mut terminal, &mut state, host.output())?;
        }

        match events_rx.recv_timeout(Duration::from_millis(100)) {
            Ok(LoopEvent::Packet(packet)) => {
                handle_packet(
                    &packet,
                    &mut state,
                    &mut renderer,
                    &mut terminal,
                    host.output(),
                )?;
            }
            Ok(LoopEvent::Input(event)) => {
                handle_input_event(event, &mut terminal, &mut state, host.output())?;
            }
            Ok(LoopEvent::BackendClosed) => {
                backend_closed = true;
                break;
            }
            Err(RecvTimeoutError::Timeout) => {
                if let Some((width, height)) = terminal.poll_size()? {
                    state.resize(width, height);
                    beam_host::send_resize(host.output(), width, height)?;
                }
            }
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }

    terminal.finish()?;

    if backend_closed
        && let Some(status) = host.finish()
        && !status.success()
    {
        return Err(io::Error::other(format!("BEAM child exited with {status}")));
    }

    host.shutdown();
    Ok(())
}

fn spawn_packet_reader(mut reader: Box<dyn beam_host::PacketReader>, events_tx: Sender<LoopEvent>) {
    thread::spawn(move || {
        loop {
            match beam_host::read_framed_packet(&mut reader) {
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
    terminal: &mut Terminal,
    state: &mut SemanticState,
    output: &mut (impl Write + ?Sized),
) -> io::Result<()> {
    if let Some((width, height)) = terminal.poll_size()? {
        let _timer = animation::RESIZE_SETTLE.timer();
        state.resize(width, height);
        beam_host::send_resize(output, width, height)?;
    }
    Ok(())
}

fn handle_input_event(
    event: input::Event,
    terminal: &mut Terminal,
    state: &mut SemanticState,
    output: &mut (impl Write + ?Sized),
) -> io::Result<()> {
    match event {
        input::Event::Resize { cols, rows } => {
            state.resize(cols, rows);
            beam_host::send_resize(output, cols, rows)?;
            if let Some((width, height)) = terminal.poll_size()? {
                state.resize(width, height);
            }
            Ok(())
        }
        input::Event::Key { .. } | input::Event::Paste(_) => {
            beam_host::send_input_event(event, output)
        }
    }
}

fn handle_packet(
    packet: &[u8],
    state: &mut SemanticState,
    renderer: &mut SemanticRenderer,
    terminal: &mut Terminal,
    output: &mut (impl Write + ?Sized),
) -> io::Result<()> {
    let mut should_render = false;

    for decoded in beam_host::decode_packet(packet) {
        let command = match decoded {
            Ok(command) => command,
            Err(error) => {
                beam_host::log_warn(
                    output,
                    &format!("protocol decode error at {}: {}", error.offset, error.error),
                );
                break;
            }
        };

        let effect = state.apply_protocol_command(command);
        if let Some(title) = effect.title {
            terminal.set_title(&title)?;
        }
        if let Some(clipboard) = effect.clipboard
            && clipboard.target == 0
        {
            terminal.write_clipboard(&clipboard.text)?;
        }
        should_render |= effect.render;
    }

    if should_render && let Err(error) = renderer.render(state, terminal) {
        beam_host::log_warn(output, &format!("render error: {error}"));
    }

    Ok(())
}
