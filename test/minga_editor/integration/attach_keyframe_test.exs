defmodule Minga.Integration.AttachKeyframeTest do
  @moduledoc """
  Child F of epic #2219: a second frontend attaches to a running session via a
  keyframe (AC-6 prototype).

  ## What this proves

  A second frontend that connects to a running editor session and sends
  `request_keyframe(0)` on first contact receives a complete keyframe transaction
  (base_frame_seq 0, full snapshots of every window and every chrome surface) and
  decodes to state equivalent to the first client's last committed frame.

  ## A-vs-B: the single-port attach variant, stated honestly

  `MingaEditor.Frontend.Manager` manages exactly ONE Port, and the epic's locked
  spec keeps it that way ("Manager is opaque transport ... must stay that way";
  the owner-call default scopes Manager fan-out OUT of this prototype). So this
  test does NOT run two simultaneous live connections off one emitter. Instead it
  exercises the attach MECHANISM over the existing single-port lifecycle:

    1. A first client (HeadlessPort A) drives a session and commits state.
    2. A second client connects: it becomes the editor's port_manager (the new
       frontend) and sends `request_keyframe(0)` as its first-contact attach
       handshake.
    3. The editor forces the next frame to a global full keyframe and emits it to
       the new client.
    4. The keyframe transaction is asserted structurally (base_frame_seq 0, every
       window emitted as full `gui_window_content`, chrome surfaces present) and
       decoded through a fresh HeadlessPort, whose rendered screen is compared to
       client A's committed snapshot.

  The first test drives the keyframe with `request_keyframe(0)` ALONE (no `ready`),
  so the keyframe is provably caused by the request, not by the `:ready` handler's
  `reset_frontend_render_state` (which also zeroes the delta base; see the second
  test for that reconnect-handshake variant).

  AC-2 ("the first client survives") holds in the single-port variant as: client
  A's committed state is untouched by the attach, and because the keyframe is
  GLOBAL (not per-client), the frame the new client receives is the same logical
  frame client A already holds. Per-client delta divergence is explicitly the
  daemon epic's scope, not this prototype's.

  ## Limits

  - One emitter, so the two clients are demonstrated across a port handoff, not as
    two truly concurrent live sinks. A real daemon would fan one frame out to many
    transports; that is out of scope here.
  - The keyframe is global-full. There is no per-client base tracking, so attach
    cost does not yet scale down with client count. The daemon epic owns that.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Protocol.Opcodes
  alias MingaEditor.Frontend.Capabilities
  alias Minga.Test.HeadlessPort
  alias Minga.Test.RecordingFrontend

  @op_begin_frame Opcodes.begin_frame()
  @op_commit_frame Opcodes.commit_frame()
  @op_gui_window_content Opcodes.gui_window_content()
  @op_gui_window_viewport_delta Opcodes.gui_window_viewport_delta()
  @op_gui_window_rows_delta Opcodes.gui_window_rows_delta()
  @op_gui_window_overlay_delta Opcodes.gui_window_overlay_delta()
  @op_gui_status_bar Opcodes.gui_status_bar()
  @op_gui_minibuffer Opcodes.gui_minibuffer()
  @op_gui_line_spacing Opcodes.gui_line_spacing()
  @op_gui_cursor_animation Opcodes.gui_cursor_animation()
  @op_gui_config_state Opcodes.gui_config_state()

  @width 80
  @height 24

  test "request_keyframe(0) is the attach handshake: a second client renders the committed state" do
    # ── First client: drive a running session and commit state ────────────────
    ctx = start_editor("first line\nsecond line\nthird line", width: @width, height: @height)

    # Edit so the committed state is non-trivial and differs from the boot frame:
    # append a "!" to line one in insert mode, then return to normal.
    send_keys(ctx, "A!<Esc>")
    sync_screen(ctx)

    committed = capture_committed_snapshot(ctx)

    # Sanity: the edit really landed in the first client's committed frame, and
    # the session has emitted several non-keyframe frames (so the next frame would
    # be a DELTA unless something forces a keyframe).
    assert Enum.any?(committed.rows, &String.contains?(&1, "first line!")),
           "expected first client to have committed the edit, got rows: #{inspect(committed.rows)}"

    assert editor_state(ctx).caches.last_emitted_frame_seq > 0,
           "expected the running session to have a non-zero committed frame base"

    # ── Second client connects mid-session ────────────────────────────────────
    # The new frontend becomes the editor's port_manager. The first client's
    # captured snapshot above is frozen test-process data, unaffected by anything
    # the editor does next, so it literally survives the attach.
    {:ok, recorder} =
      RecordingFrontend.start_link(owner: self(), width: @width, height: @height)

    attach_client!(ctx.editor, recorder)

    # ── Attach handshake: request_keyframe(0) ONLY ────────────────────────────
    # No `ready` is sent, so the keyframe cannot be an artifact of the :ready
    # handler's reset_frontend_render_state. The editor forces the next frame to a
    # global full keyframe (base_frame_seq 0) purely because of request_keyframe.
    # Headless backend renders synchronously, so a sync barrier guarantees the
    # keyframe batch has been cast to the new client.
    send(ctx.editor, {:minga_input, {:request_keyframe, 0}})
    _ = GenServer.call(ctx.editor, :api_mode, 15_000)

    keyframe_batch = await_keyframe_batch(recorder)

    # ── AC: the transaction is a complete keyframe ────────────────────────────
    assert_keyframe_transaction!(keyframe_batch)

    # ── AC-1: the new client decodes to state equivalent to the committed frame ─
    attached_screen = decode_through_headless(keyframe_batch)

    assert_screen_equivalent!(attached_screen, committed)
  end

  test "the attach keyframe re-emits every chrome surface and full window content" do
    ctx = start_editor("alpha\nbeta", width: @width, height: @height)
    send_keys(ctx, "ix<Esc>")
    sync_screen(ctx)

    {:ok, recorder} =
      RecordingFrontend.start_link(owner: self(), width: @width, height: @height)

    attach_client!(ctx.editor, recorder)
    send(ctx.editor, {:minga_input, {:request_keyframe, 0}})
    _ = GenServer.call(ctx.editor, :api_mode, 15_000)

    keyframe_batch = await_keyframe_batch(recorder)
    opcodes = Enum.map(keyframe_batch, fn <<op, _rest::binary>> -> op end)

    # A keyframe re-establishes the frontend from scratch: the modeline-bearing
    # status bar and the minibuffer/echo-area chrome must both be present so the
    # attached client paints complete chrome, not just editor windows.
    assert @op_gui_status_bar in opcodes,
           "keyframe must re-emit the status bar; opcodes were #{inspect(opcodes)}"

    assert @op_gui_minibuffer in opcodes,
           "keyframe must re-emit the minibuffer; opcodes were #{inspect(opcodes)}"

    assert @op_gui_window_content in opcodes,
           "keyframe must carry full window content; opcodes were #{inspect(opcodes)}"

    # No window appears as a delta in a keyframe: every window is a full snapshot.
    refute Enum.any?(
             opcodes,
             &(&1 in [
                 @op_gui_window_viewport_delta,
                 @op_gui_window_rows_delta,
                 @op_gui_window_overlay_delta
               ])
           ),
           "a keyframe must carry full window content, never deltas; opcodes were #{inspect(opcodes)}"
  end

  test "the attach keyframe carries the GUI config settings without any runtime config change (#2119)" do
    # A native GUI session: line_spacing, cursor_animation, and config_state are
    # emitted in-frame as semantic models (#2119), not pushed out-of-band at
    # startup. So a late-attaching client's keyframe must carry all three with the
    # CURRENT config values, even though no setting changes during the attach.
    # Isolated options server: a :native_gui startup PROMOTES an unset
    # line_spacing (1.0 -> 1.2) by writing the option, so running this against
    # the global server would mutate state concurrent async tests read.
    id = :erlang.unique_integer([:positive])
    events_registry = :"attach_gui_config_events_#{id}"
    start_supervised!({Minga.Events, name: events_registry})

    options_server =
      start_supervised!({Minga.Config.Options, name: nil, events_registry: events_registry},
        id: {:attach_gui_config_options, id}
      )

    gui_caps = %Capabilities{frontend_type: :native_gui}

    ctx =
      start_editor("alpha\nbeta",
        width: @width,
        height: @height,
        capabilities: gui_caps,
        options_server: options_server
      )

    send_keys(ctx, "ix<Esc>")
    sync_screen(ctx)

    {:ok, recorder} =
      RecordingFrontend.start_link(
        owner: self(),
        width: @width,
        height: @height,
        capabilities: gui_caps
      )

    attach_client!(ctx.editor, recorder)
    send(ctx.editor, {:minga_input, {:request_keyframe, 0}})
    _ = GenServer.call(ctx.editor, :api_mode, 15_000)

    keyframe_batch = await_keyframe_batch(recorder)
    opcodes = Enum.map(keyframe_batch, fn <<op, _rest::binary>> -> op end)

    assert @op_gui_line_spacing in opcodes,
           "keyframe must re-emit line_spacing; opcodes were #{inspect(opcodes)}"

    assert @op_gui_cursor_animation in opcodes,
           "keyframe must re-emit cursor_animation; opcodes were #{inspect(opcodes)}"

    assert @op_gui_config_state in opcodes,
           "keyframe must re-emit config_state; opcodes were #{inspect(opcodes)}"

    # The re-emitted values are the current config, decoded from the keyframe
    # bytes against the SAME (isolated) options server the editor read.
    assert keyframe_line_spacing(keyframe_batch) ==
             round((Minga.Config.Options.get(options_server, :line_spacing) || 1.0) * 100)

    assert keyframe_cursor_animation(keyframe_batch) ==
             Minga.Config.Options.get(options_server, :cursor_animate)
  end

  test "reconnect handshake: a fresh `ready` also keyframes the attaching client by construction" do
    # The other half of the attach mechanism: a frontend that (re)connects and
    # sends `ready` triggers reset_frontend_render_state, which zeroes the delta
    # base so the very next frame is a keyframe even without an explicit
    # request_keyframe. This is the "first frame after reconnect keyframes by
    # construction" property the daemon epic relies on.
    ctx = start_editor("one\ntwo\nthree", width: @width, height: @height)
    send_keys(ctx, "A.<Esc>")
    sync_screen(ctx)

    committed = capture_committed_snapshot(ctx)
    assert editor_state(ctx).caches.last_emitted_frame_seq > 0

    {:ok, recorder} =
      RecordingFrontend.start_link(owner: self(), width: @width, height: @height)

    attach_client!(ctx.editor, recorder)

    # Re-ready (no request_keyframe). The :ready handler resets frontend render
    # state, so the next emitted frame is a keyframe.
    send(ctx.editor, {:minga_input, {:ready, @width, @height}})
    _ = GenServer.call(ctx.editor, :api_mode, 15_000)

    keyframe_batch = await_keyframe_batch(recorder)
    assert_keyframe_transaction!(keyframe_batch)

    attached_screen = decode_through_headless(keyframe_batch)
    assert_screen_equivalent!(attached_screen, committed)
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Decodes the spacing_x100 value out of the keyframe's gui_line_spacing command
  # (opcode + payload_length(2) + spacing_x100(2)).
  defp keyframe_line_spacing(batch) do
    Enum.find_value(batch, fn
      <<@op_gui_line_spacing, _len::16, spacing_x100::16>> -> spacing_x100
      _ -> nil
    end)
  end

  # Decodes the enabled flag out of the keyframe's gui_cursor_animation command
  # (opcode + payload_length(2) + enabled(1)).
  defp keyframe_cursor_animation(batch) do
    Enum.find_value(batch, fn
      <<@op_gui_cursor_animation, _len::16, enabled::8>> -> enabled == 1
      _ -> nil
    end)
  end

  # Captures the first client's last committed frame as frozen test-process data
  # (rows + cursor). Reads the live HeadlessPort grid after a sync barrier; the
  # returned map is a plain copy, so nothing the editor does later mutates it.
  defp capture_committed_snapshot(ctx) do
    screen = HeadlessPort.get_screen(ctx.port)

    rows =
      Enum.map(screen.grid, fn row ->
        row |> Enum.map_join(& &1.char) |> String.trim_trailing()
      end)

    %{rows: rows, cursor: screen.cursor}
  end

  # Swaps the editor's port_manager to the newly-connected client. In production
  # the Manager owns a single Port; in this prototype the "second frontend" is a
  # fresh adapter the editor now emits to. :sys.replace_state is the standard
  # test technique in this suite (see EditorCase.ensure_test_buffer_id/1).
  defp attach_client!(editor, client) do
    :sys.replace_state(editor, fn state -> %{state | port_manager: client} end)
  end

  # Waits for the keyframe command batch the editor cast to the newly-attached
  # client. RecordingFrontend forwards each batch to its owner as
  # {:frontend_commands, server, commands}. We take the first batch that opens
  # with begin_frame (the keyframe transaction).
  defp await_keyframe_batch(recorder) do
    receive do
      {:frontend_commands, ^recorder, commands} ->
        if Enum.any?(commands, &match?(<<@op_begin_frame, _::binary>>, &1)) do
          commands
        else
          await_keyframe_batch(recorder)
        end
    after
      5_000 -> flunk("did not receive a keyframe batch from the attached client")
    end
  end

  # Asserts the batch is a complete keyframe transaction:
  #   * opens with begin_frame, base_frame_seq == 0 (the keyframe marker)
  #   * closes with commit_frame whose frame_seq matches the begin
  #   * carries at least one full gui_window_content (full snapshot, no deltas)
  defp assert_keyframe_transaction!(commands) do
    [<<@op_begin_frame, frame_seq::32, base_frame_seq::32>> | _] = commands

    assert base_frame_seq == 0,
           "attach handshake must produce a keyframe (base_frame_seq 0), got #{base_frame_seq}"

    last = Enum.at(commands, -1)

    assert <<@op_commit_frame, commit_seq::32, _input_seq::32>> = last

    assert commit_seq == frame_seq,
           "commit_frame seq (#{commit_seq}) must match the open begin_frame seq (#{frame_seq})"

    opcodes = Enum.map(commands, fn <<op, _rest::binary>> -> op end)

    assert @op_gui_window_content in opcodes,
           "a keyframe must emit at least one full gui_window_content snapshot"

    # No window deltas may appear inside a keyframe.
    refute Enum.any?(
             opcodes,
             &(&1 in [
                 @op_gui_window_viewport_delta,
                 @op_gui_window_rows_delta,
                 @op_gui_window_overlay_delta
               ])
           ),
           "a keyframe must not carry window deltas"
  end

  # Replays the recorded keyframe batch through a fresh HeadlessPort, exactly as a
  # newly-attached frontend would decode it, and returns its rendered screen.
  defp decode_through_headless(commands) do
    {:ok, port} = HeadlessPort.start_link(width: @width, height: @height)
    ref = HeadlessPort.prepare_await(port)
    HeadlessPort.send_commands(port, commands)
    {:ok, snapshot} = HeadlessPort.collect_frame(ref, 5_000)

    rows =
      Enum.map(snapshot.grid, fn row ->
        row |> Enum.map_join(& &1.char) |> String.trim_trailing()
      end)

    %{rows: rows, cursor: snapshot.cursor}
  end

  # Equivalence = the attached client's decoded screen renders the same committed
  # content and cursor as the first client's last committed frame. We compare
  # semantic decoded output (rendered rows + cursor), not live-model internals or
  # raw bytes.
  defp assert_screen_equivalent!(attached, committed) do
    assert attached.cursor == committed.cursor,
           "attached cursor #{inspect(attached.cursor)} != committed cursor #{inspect(committed.cursor)}"

    assert attached.rows == committed.rows, """
    attached client did not render the committed state.

    committed rows:
    #{format_rows(committed.rows)}

    attached rows:
    #{format_rows(attached.rows)}
    """
  end

  defp format_rows(rows) do
    rows
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {row, i} -> "  #{i}: #{inspect(row)}" end)
  end
end
