defmodule MingaEditor.Frontend.Emit.KeyframeSideChannelTest do
  @moduledoc """
  Regression coverage for keyframe side-channel symmetry (#2219).

  A forced keyframe re-establishes the frontend from scratch. It must reset not
  only the adapter delta caches but also the title and window-background side
  channels (`last_title` / `last_window_bg`), so a frontend that lost its title or
  background mid-session gets them back on the keyframe.

  Frame and side-channel writes share the frame context's frontend, so this test observes both through one recording adapter.
  """

  use ExUnit.Case, async: true

  alias Minga.Protocol.Opcodes
  alias Minga.Test.RecordingFrontend
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Frontend.Emit
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Renderer.Caches
  alias Minga.RenderModel.Window, as: RenderWindow
  alias Minga.RenderModel.Window.Row, as: RenderRow
  alias Minga.RenderModel.Window.Span, as: RenderSpan

  import MingaEditor.RenderPipeline.TestHelpers

  @op_begin_frame Opcodes.begin_frame()

  setup do
    frontend =
      start_supervised!(
        {RecordingFrontend, owner: self()},
        id: {:keyframe_side_channel_frontend, System.unique_integer([:positive])}
      )

    Process.put(:keyframe_side_channel_frontend, frontend)
    :ok
  end

  test "a forced keyframe re-sends the title and window background even when unchanged" do
    frame = window_frame_with_content()
    state = semantic_state()
    title_op = Opcodes.set_title()
    bg_op = Opcodes.set_window_bg()

    # Establish populated side-channel caches via two frames. The first frame is a
    # keyframe (no committed base) and sends both side channels; flush them.
    {_c1, caches} = emit_and_capture(frame, state, %Caches{}, frame_seq: 11)
    caches = Caches.acknowledge_frame(caches, 11, caches.recovery_generation)
    flush_side_channels(title_op, bg_op)
    {_c2, caches} = emit_and_capture(frame, state, caches, frame_seq: 22)
    caches = Caches.acknowledge_frame(caches, 22, caches.recovery_generation)

    assert is_binary(caches.last_title)
    assert is_integer(caches.last_window_bg)

    # A delta frame with the same title/bg sends neither side channel (cache hit).
    {_c3, caches} = emit_and_capture(frame, state, caches, frame_seq: 24)
    refute_received {:frontend_commands, _frontend, [<<^title_op, _::binary>>]}
    refute_received {:frontend_commands, _frontend, [<<^bg_op, _::binary>>]}

    # The forced keyframe drops last_title/last_window_bg, so both re-send even though
    # the values are unchanged from the prior frame (mirrors reset_frontend_state/1).
    {_key, key_caches} =
      emit_and_capture(frame, state, caches, frame_seq: 33, force_keyframe?: true)

    assert key_caches.last_frame_keyframe?
    assert_received {:frontend_commands, _frontend, [<<^title_op, _::binary>>]}
    assert_received {:frontend_commands, _frontend, [<<^bg_op, _::binary>>]}
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp semantic_state do
    %{emit_state() | capabilities: %Capabilities{frontend_type: :tui, semantic_ui: true}}
  end

  defp window_frame_with_content do
    frame = build_frame_with_window(emit_state(), viewport_top: 0)

    row = %RenderRow{
      row_id: RenderRow.stable_id(:normal, 0),
      row_type: :normal,
      buf_line: 0,
      text: "semantic",
      spans: [%RenderSpan{start_col: 0, end_col: 8, fg: 0xBBC2CF, bg: 0x282C34, attrs: 0}]
    }

    window_model = %RenderWindow{
      window_id: 1,
      content_kind: :buffer,
      rect: {0, 0, 80, 20},
      rows: [row],
      cursor_row: 0,
      cursor_col: 0,
      cursor_shape: :block
    }

    %{frame | windows: [window_model]}
  end

  defp emit_and_capture(frame, state, caches, opts) do
    ctx = %{
      Context.from_editor_state(state)
      | frame_seq: Keyword.fetch!(opts, :frame_seq),
        force_keyframe?: Keyword.get(opts, :force_keyframe?, false)
    }

    {new_caches, _font_registry, _message_store} = Emit.emit(frame, ctx, nil, caches)

    assert_receive {:frontend_commands, _frontend, [<<@op_begin_frame, _::binary>> | _]}

    {nil, new_caches}
  end

  defp flush_side_channels(title_op, bg_op) do
    receive do
      {:frontend_commands, _frontend, [<<^title_op, _::binary>>]} ->
        flush_side_channels(title_op, bg_op)

      {:frontend_commands, _frontend, [<<^bg_op, _::binary>>]} ->
        flush_side_channels(title_op, bg_op)
    after
      0 -> :ok
    end
  end

  defp emit_state(opts \\ []) do
    frontend = Process.get(:keyframe_side_channel_frontend)
    base_state(Keyword.put(opts, :port_manager, frontend))
  end
end
