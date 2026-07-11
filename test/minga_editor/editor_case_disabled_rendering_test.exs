defmodule MingaEditor.EditorCaseDisabledRenderingTest do
  @moduledoc "Contract tests for EditorCase's input-only rendering policy."

  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias Minga.Test.HeadlessPort
  alias MingaEditor.HighlightSync

  test "readiness and operator-pending input commit no frames while edits still apply" do
    ctx = start_editor("one\ntwo")

    assert HeadlessPort.frame_count(ctx.port) == 0
    assert editor_mode(ctx) == :normal

    send_key_sync(ctx, ?d)

    assert editor_mode(ctx) == :operator_pending
    assert HeadlessPort.frame_count(ctx.port) == 0

    send_key_sync(ctx, ?d)

    assert editor_mode(ctx) == :normal
    assert buffer_content(ctx) == "two"
    assert HeadlessPort.frame_count(ctx.port) == 0
  end

  test "insert input and mode changes commit no frames while buffer state changes" do
    ctx = start_editor("hello")

    send_key_sync(ctx, ?i)
    assert editor_mode(ctx) == :insert
    assert HeadlessPort.frame_count(ctx.port) == 0

    send_key_sync(ctx, ?X)
    assert buffer_content(ctx) == "Xhello"
    assert HeadlessPort.frame_count(ctx.port) == 0

    send_key_sync(ctx, 27)
    assert editor_mode(ctx) == :normal
    assert HeadlessPort.frame_count(ctx.port) == 0
  end

  test "highlight events update state without bypassing the rendering policy" do
    ctx = start_editor("defmodule Example do\nend")
    spans = [%{start_byte: 0, end_byte: 9, capture_id: 0}]

    inject_highlights(ctx, ["keyword"], 1, spans)

    assert HighlightSync.get_active_highlight(editor_state(ctx)).spans == List.to_tuple(spans)
    assert HeadlessPort.frame_count(ctx.port) == 0
  end

  test "frame-dependent helpers fail immediately with the rendering policy" do
    ctx = start_editor("hello")

    assert_raise ArgumentError, ~r/send_key\/3 requires rendering.*rendering: :disabled/, fn ->
      send_key(ctx, ?l)
    end

    assert_raise ArgumentError, ~r/screen_row\/2 requires rendering.*rendering: :disabled/, fn ->
      screen_row(ctx, 0)
    end

    assert_raise ArgumentError, ~r/send_resize\/3 requires rendering.*rendering: :disabled/, fn ->
      send_resize(ctx, 100, 30)
    end
  end
end
