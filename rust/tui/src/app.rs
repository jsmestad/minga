use crate::animation;
use crate::beam_host::{self, FrontendCapabilities};
use crate::images;
use crate::input;
use crate::parity::{FrontendParityPolicy, GO_ZIG_PARITY};
use crate::protocol;
use crate::render_scheduler::{RenderBatch, RenderScheduler};
use crate::runtime::{DrainDecision, FrameRuntime};
use crate::semantic_renderer::{SemanticRenderer, RECONCILIATION_INTERVAL};
use crate::semantic_state::{DirtyKind, SemanticState};
use crate::signals;
use crate::terminal::Terminal;
use crossterm::event;
use std::io::{self, Write};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender, TryRecvError};
use std::thread;
use std::time::{Duration, Instant};

#[derive(Debug)]
enum LoopEvent {
    Packet {
        packet: Vec<u8>,
        received_at: Instant,
    },
    Input {
        event: input::Event,
        received_at: Instant,
    },
    BackendClosed,
}

struct RuntimeLoop {
    policy: FrontendParityPolicy,
    startup_started: Instant,
    first_backend_packet_seen: bool,
    render_scheduler: RenderScheduler,
    frame_runtime: FrameRuntime,
}

pub fn run() -> io::Result<()> {
    run_with_policy(GO_ZIG_PARITY)
}

fn run_with_policy(policy: FrontendParityPolicy) -> io::Result<()> {
    let startup_started = Instant::now();
    let mut terminal = Terminal::open(policy.terminal)?;
    let (cols, rows) = terminal.size();
    SemanticRenderer::render_startup(&mut terminal, "Starting Minga editor core...")?;
    beam_host::trace(format!(
        "startup local_first_paint_ms={}",
        startup_started.elapsed().as_millis()
    ));

    let beam_spawn_started = Instant::now();
    let mut host = beam_host::open();
    beam_host::trace(format!(
        "startup protocol_open_ms={} total_ms={}",
        beam_spawn_started.elapsed().as_millis(),
        startup_started.elapsed().as_millis()
    ));
    let image_support = images::ImageSupport::default();

    beam_host::send_ready(
        host.output(),
        FrontendCapabilities {
            width: cols,
            height: rows,
            image_support: image_support.capability_code(),
        },
    )?;
    beam_host::trace(format!(
        "started semantic rust tui size={cols}x{rows} image_support={}",
        image_support.capability_code()
    ));

    let mut state = SemanticState::new(cols, rows);
    let mut renderer = SemanticRenderer::new();
    let resize_signal = signals::ResizeSignal::install().ok();
    let (events_tx, events_rx) = mpsc::channel();
    spawn_packet_reader(host.take_reader()?, events_tx.clone());
    spawn_input_reader(events_tx, policy.input);
    let mut runtime = RuntimeLoop {
        policy,
        startup_started,
        first_backend_packet_seen: false,
        render_scheduler: RenderScheduler::default(),
        frame_runtime: FrameRuntime::new(policy.frame),
    };

    loop {
        if resize_signal
            .as_ref()
            .is_some_and(signals::ResizeSignal::take)
        {
            publish_resize(&mut terminal, &mut state, host.output())?;
        }

        match events_rx.recv_timeout(Duration::from_millis(100)) {
            Ok(event) => {
                let mut backend_closed = false;
                if process_loop_event(
                    event,
                    &mut runtime,
                    &mut terminal,
                    &mut state,
                    &mut renderer,
                    host.output(),
                )? {
                    backend_closed = true;
                }

                flush_scheduled_render(
                    &mut runtime.render_scheduler,
                    runtime.policy,
                    &mut renderer,
                    &state,
                    &mut terminal,
                )?;

                while !backend_closed {
                    match events_rx.try_recv() {
                        Ok(event) => {
                            backend_closed = process_loop_event(
                                event,
                                &mut runtime,
                                &mut terminal,
                                &mut state,
                                &mut renderer,
                                host.output(),
                            )?;
                            flush_scheduled_render(
                                &mut runtime.render_scheduler,
                                runtime.policy,
                                &mut renderer,
                                &state,
                                &mut terminal,
                            )?;
                        }
                        Err(TryRecvError::Empty) => break,
                        Err(TryRecvError::Disconnected) => return Ok(()),
                    }
                }

                if !backend_closed {
                    backend_closed = drain_coalescing_window(
                        &events_rx,
                        &mut runtime,
                        &mut terminal,
                        &mut state,
                        &mut renderer,
                        host.output(),
                    )?;
                }

                flush_scheduled_render(
                    &mut runtime.render_scheduler,
                    runtime.policy,
                    &mut renderer,
                    &state,
                    &mut terminal,
                )?;

                if backend_closed {
                    break;
                }
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
    host.shutdown();
    Ok(())
}

fn drain_coalescing_window(
    events_rx: &Receiver<LoopEvent>,
    runtime: &mut RuntimeLoop,
    terminal: &mut Terminal,
    state: &mut SemanticState,
    renderer: &mut SemanticRenderer,
    output: &mut (impl Write + ?Sized),
) -> io::Result<bool> {
    if !runtime.render_scheduler.pending() || runtime.policy.frame.packet_coalesce_us == 0 {
        return Ok(false);
    }

    let Some(deadline) = runtime.frame_runtime.coalescing_deadline(Instant::now()) else {
        return Ok(false);
    };

    loop {
        match runtime
            .frame_runtime
            .drain_decision(Instant::now(), deadline)
        {
            DrainDecision::Render => return Ok(false),
            DrainDecision::Wait(timeout) => match events_rx.recv_timeout(timeout) {
                Ok(event) => {
                    if process_loop_event(event, runtime, terminal, state, renderer, output)? {
                        return Ok(true);
                    }
                }
                Err(RecvTimeoutError::Timeout) => return Ok(false),
                Err(RecvTimeoutError::Disconnected) => return Ok(true),
            },
        }
    }
}

fn process_loop_event(
    event: LoopEvent,
    runtime: &mut RuntimeLoop,
    terminal: &mut Terminal,
    state: &mut SemanticState,
    renderer: &mut SemanticRenderer,
    output: &mut (impl Write + ?Sized),
) -> io::Result<bool> {
    match event {
        LoopEvent::Packet {
            packet,
            received_at,
        } => {
            if !runtime.first_backend_packet_seen {
                runtime.first_backend_packet_seen = true;
                beam_host::trace(format!(
                    "startup first_backend_packet_ms={}",
                    runtime.startup_started.elapsed().as_millis()
                ));
            }
            match handle_packet(
                &packet,
                received_at,
                runtime.policy,
                state,
                terminal,
                output,
            )? {
                Some(DirtyKind::Partial) => runtime.render_scheduler.request_partial(),
                Some(DirtyKind::Full) => runtime.render_scheduler.request(),
                None => {}
            }
            Ok(false)
        }
        LoopEvent::Input { event, received_at } => {
            handle_input_event(
                event,
                received_at,
                runtime.policy,
                terminal,
                state,
                renderer,
                output,
            )?;
            Ok(false)
        }
        LoopEvent::BackendClosed => Ok(true),
    }
}

fn flush_scheduled_render(
    render_scheduler: &mut RenderScheduler,
    policy: FrontendParityPolicy,
    renderer: &mut SemanticRenderer,
    state: &SemanticState,
    terminal: &mut Terminal,
) -> io::Result<()> {
    let Some(batch) = render_scheduler.take_ready() else {
        return Ok(());
    };

    render_now(batch, policy, renderer, state, terminal)
}

fn render_now(
    batch: RenderBatch,
    policy: FrontendParityPolicy,
    renderer: &mut SemanticRenderer,
    state: &SemanticState,
    terminal: &mut Terminal,
) -> io::Result<()> {
    let use_incremental = batch.dirty == DirtyKind::Partial
        && terminal.is_real_tty()
        && renderer.incremental_frame_count < RECONCILIATION_INTERVAL;

    if use_incremental {
        match renderer.render_incremental(state, terminal) {
            Ok(metrics) if policy.tracing.render_latency => {
                let surfaces = metrics.surfaces;
                beam_host::trace(format!(
                    "latency render render_mode=incremental requests={} pending_us={} cursor_style_us={} draw_us={} flush_us={} total_us={} windows_us={} chrome_us={} state={}",
                    batch.request_count,
                    batch.pending_us,
                    metrics.cursor_style_us,
                    metrics.draw_us,
                    metrics.flush_us,
                    metrics.total_us,
                    surfaces.windows_us,
                    surfaces.chrome_us,
                    state.debug_summary()
                ));
                Ok(())
            }
            Ok(_) => Ok(()),
            Err(error) => {
                beam_host::trace(format!("render incremental failed error={error}, falling back to full"));
                // Fall back to full render on incremental failure
                renderer.incremental_frame_count = 0;
                render_full(batch, policy, renderer, state, terminal)
            }
        }
    } else {
        if renderer.incremental_frame_count > 0 {
            let _ = terminal.clear_for_reconciliation();
        }
        render_full(batch, policy, renderer, state, terminal)
    }
}

fn render_full(
    batch: RenderBatch,
    policy: FrontendParityPolicy,
    renderer: &mut SemanticRenderer,
    state: &SemanticState,
    terminal: &mut Terminal,
) -> io::Result<()> {
    match renderer.render_with_metrics(state, terminal) {
        Ok(metrics) if policy.tracing.render_latency => {
            let surfaces = metrics.surfaces;
            beam_host::trace(format!(
                "latency render render_mode=full requests={} pending_us={} cursor_style_us={} draw_us={} flush_us={} total_us={} clear_us={} tree_us={} windows_us={} separators_us={} overlays_us={} bottom_panel_us={} chrome_us={} state={}",
                batch.request_count,
                batch.pending_us,
                metrics.cursor_style_us,
                metrics.draw_us,
                metrics.flush_us,
                metrics.total_us,
                surfaces.clear_us,
                surfaces.tree_us,
                surfaces.windows_us,
                surfaces.separators_us,
                surfaces.overlays_us,
                surfaces.bottom_panel_us,
                surfaces.chrome_us,
                state.debug_summary()
            ));
            Ok(())
        }
        Ok(_) => Ok(()),
        Err(error) => {
            beam_host::trace(format!("render failed error={error}"));
            Ok(())
        }
    }
}

fn spawn_packet_reader(mut reader: Box<dyn beam_host::PacketReader>, events_tx: Sender<LoopEvent>) {
    thread::spawn(move || {
        loop {
            match beam_host::read_framed_packet(&mut reader) {
                Ok(Some(packet)) => {
                    let received_at = Instant::now();
                    beam_host::trace(format!(
                        "packet read len={} head={}",
                        packet.len(),
                        packet_head(&packet)
                    ));
                    if events_tx
                        .send(LoopEvent::Packet {
                            packet,
                            received_at,
                        })
                        .is_err()
                    {
                        break;
                    }
                }
                Ok(None) => {
                    beam_host::trace("packet reader reached eof");
                    let _ = events_tx.send(LoopEvent::BackendClosed);
                    break;
                }
                Err(_) => {
                    beam_host::trace("packet reader failed");
                    let _ = events_tx.send(LoopEvent::BackendClosed);
                    break;
                }
            }
        }
    });
}

fn spawn_input_reader(events_tx: Sender<LoopEvent>, policy: crate::parity::InputPolicy) {
    thread::spawn(move || {
        while let Ok(event) = event::read() {
            let received_at = Instant::now();
            if let Some(event) = input::map_crossterm_event_with_policy(event, policy)
                && events_tx
                    .send(LoopEvent::Input { event, received_at })
                    .is_err()
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
    received_at: Instant,
    policy: FrontendParityPolicy,
    terminal: &mut Terminal,
    state: &mut SemanticState,
    renderer: &mut SemanticRenderer,
    output: &mut (impl Write + ?Sized),
) -> io::Result<()> {
    let kind = input_event_name(&event);
    let detail = input_event_detail(&event);
    let queued_us = received_at.elapsed().as_micros();
    let write_started = Instant::now();
    let result = match event {
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
        input::Event::Mouse { .. } => {
            if policy.input.semantic_clicks_before_raw_mouse
                && let Some(packet) = renderer.semantic_mouse_packet(state, &event)
            {
                protocol::write_packet(output, &packet)
            } else {
                beam_host::send_input_event(event, output)
            }
        }
    };
    if policy.tracing.input_latency {
        beam_host::trace(format!(
            "latency input kind={} detail={} queue_us={} write_us={}",
            kind,
            detail,
            queued_us,
            write_started.elapsed().as_micros()
        ));
    }
    result
}

fn input_event_name(event: &input::Event) -> &'static str {
    match event {
        input::Event::Key { .. } => "key",
        input::Event::Paste(_) => "paste",
        input::Event::Resize { .. } => "resize",
        input::Event::Mouse { .. } => "mouse",
    }
}

fn input_event_detail(event: &input::Event) -> String {
    match event {
        input::Event::Key {
            codepoint,
            modifiers,
        } => {
            let display = char::from_u32(*codepoint)
                .filter(|ch| !ch.is_control())
                .map(|ch| ch.to_string())
                .unwrap_or_else(|| "-".to_owned());
            format!("codepoint={codepoint} char={display} modifiers={modifiers}")
        }
        input::Event::Paste(bytes) => format!("bytes={}", bytes.len()),
        input::Event::Resize { cols, rows } => format!("cols={cols} rows={rows}"),
        input::Event::Mouse {
            row,
            col,
            button,
            modifiers,
            event_type,
            click_count,
        } => format!(
            "row={row} col={col} button={button} modifiers={modifiers} event_type={event_type} click_count={click_count}"
        ),
    }
}

fn handle_packet(
    packet: &[u8],
    received_at: Instant,
    policy: FrontendParityPolicy,
    state: &mut SemanticState,
    terminal: &mut Terminal,
    _output: &mut (impl Write + ?Sized),
) -> io::Result<Option<DirtyKind>> {
    let decode_started = Instant::now();
    let mut should_render = false;
    let mut packet_dirty = DirtyKind::Partial;
    let mut command_names = Vec::new();

    for decoded in beam_host::decode_packet(packet) {
        let command = match decoded {
            Ok(command) => command,
            Err(error) => {
                beam_host::trace(format!(
                    "decode error packet_len={} offset={} error={}",
                    packet.len(),
                    error.offset,
                    error.error
                ));
                break;
            }
        };

        command_names.push(command_name(&command));
        let effect = state.apply_protocol_command(command);
        if let Some(title) = effect.title {
            terminal.set_title(&title)?;
        }
        if let Some(clipboard) = effect.clipboard
            && clipboard.target == 0
        {
            terminal.write_clipboard(&clipboard.text)?;
        }
        if effect.render {
            should_render = true;
            packet_dirty = packet_dirty.merge(effect.dirty);
        }
    }

    let decode_apply_us = decode_started.elapsed().as_micros();
    if policy.tracing.packet_latency {
        beam_host::trace(format!(
            "latency packet len={} queue_us={} decode_apply_us={} render={} dirty={:?} commands=[{}] state={}",
            packet.len(),
            received_at.elapsed().as_micros(),
            decode_apply_us,
            should_render,
            packet_dirty,
            command_names.join(","),
            state.debug_summary()
        ));
    }

    Ok(if should_render {
        Some(packet_dirty)
    } else {
        None
    })
}

fn packet_head(packet: &[u8]) -> String {
    packet
        .iter()
        .take(16)
        .map(|byte| format!("{byte:02X}"))
        .collect::<Vec<_>>()
        .join(" ")
}

fn command_name(command: &protocol::Command) -> &'static str {
    match command {
        protocol::Command::Clear => "clear",
        protocol::Command::BatchEnd => "batch_end",
        protocol::Command::DrawText(_) => "draw_text",
        protocol::Command::DrawStyledText(_) => "draw_styled_text",
        protocol::Command::SetCursor { .. } => "set_cursor",
        protocol::Command::SetCursorShape(_) => "set_cursor_shape",
        protocol::Command::SetTitle(_) => "set_title",
        protocol::Command::SetWindowBg(_) => "set_window_bg",
        protocol::Command::DefineRegion(_) => "define_region",
        protocol::Command::ClearRegion(_) => "clear_region",
        protocol::Command::DestroyRegion(_) => "destroy_region",
        protocol::Command::SetActiveRegion(_) => "set_active_region",
        protocol::Command::ScrollRegion { .. } => "scroll_region",
        protocol::Command::MeasureText { .. } => "measure_text",
        protocol::Command::Semantic(command) => semantic_command_name(command),
        protocol::Command::Noop(_) => "noop",
    }
}

fn semantic_command_name(command: &crate::semantic::Command) -> &'static str {
    match command {
        crate::semantic::Command::WindowContent(_, _) => "semantic_window_content",
        crate::semantic::Command::WindowRowsDelta(_, _) => "semantic_window_rows_delta",
        crate::semantic::Command::StatusBar(_, _) => "semantic_status_bar",
        crate::semantic::Command::TabBar(_, _) => "semantic_tab_bar",
        crate::semantic::Command::FileTree(_, _) => "semantic_file_tree",
        crate::semantic::Command::FileTreeSelection(_, _) => "semantic_file_tree_selection",
        crate::semantic::Command::Picker(_, _) => "semantic_picker",
        crate::semantic::Command::PickerPreview(_, _) => "semantic_picker_preview",
        crate::semantic::Command::Minibuffer(_, _) => "semantic_minibuffer",
        crate::semantic::Command::Breadcrumb(_, _) => "semantic_breadcrumb",
        crate::semantic::Command::Completion(_, _) => "semantic_completion",
        crate::semantic::Command::WhichKey(_, _) => "semantic_which_key",
        crate::semantic::Command::SignatureHelp(_, _) => "semantic_signature_help",
        crate::semantic::Command::FloatPopup(_, _) => "semantic_float_popup",
        crate::semantic::Command::HoverPopup(_, _) => "semantic_hover_popup",
        crate::semantic::Command::BottomPanel(_, _) => "semantic_bottom_panel",
        crate::semantic::Command::ChangeSummary(_, _) => "semantic_change_summary",
        crate::semantic::Command::GitStatus(_, _) => "semantic_git_status",
        crate::semantic::Command::Gutter(_, _) => "semantic_gutter",
        crate::semantic::Command::GutterSeparator(_, _) => "semantic_gutter_separator",
        crate::semantic::Command::SplitSeparators(_, _) => "semantic_split_separators",
        crate::semantic::Command::IndentGuides(_, _) => "semantic_indent_guides",
        crate::semantic::Command::WindowOverlayDelta(_, _) => "semantic_window_overlay_delta",
        crate::semantic::Command::Cursorline(_, _) => "semantic_cursorline",
        crate::semantic::Command::LineSpacing(_, _) => "semantic_line_spacing",
        crate::semantic::Command::CursorAnimation(_, _) => "semantic_cursor_animation",
        crate::semantic::Command::ConfigState(_, _) => "semantic_config_state",
        crate::semantic::Command::AgentContext(_, _) => "semantic_agent_context",
        crate::semantic::Command::HoverAction(_, _) => "semantic_hover_action",
        crate::semantic::Command::SearchState(_, _) => "semantic_search_state",
        crate::semantic::Command::Notifications(_, _) => "semantic_notifications",
        crate::semantic::Command::ClipboardWrite(_, _) => "semantic_clipboard_write",
        crate::semantic::Command::Workspaces(_, _) => "semantic_workspaces",
        crate::semantic::Command::EditTimeline(_, _) => "semantic_edit_timeline",
        crate::semantic::Command::ExtensionOverlay(_, _) => "semantic_extension_overlay",
        crate::semantic::Command::ExtensionPanel(_, _) => "semantic_extension_panel",
        crate::semantic::Command::Observatory(_, _) => "semantic_observatory",
        crate::semantic::Command::Sidebars(_, _) => "semantic_sidebars",
        crate::semantic::Command::Board(_, _) => "semantic_board",
        crate::semantic::Command::AgentChat(_, _) => "semantic_agent_chat",
        crate::semantic::Command::ToolManager(_, _) => "semantic_tool_manager",
        crate::semantic::Command::Theme(_, _) => "semantic_theme",
    }
}
