defmodule MingaEditor.EditorCaseEnabledRenderingTest do
  @moduledoc "Smoke test for EditorCase's default rendered-frame contract."

  use Minga.Test.EditorCase, async: true

  alias Minga.Test.HeadlessPort

  test "default mode commits an initial frame and renders subsequent input" do
    ctx = start_editor("hello")
    initial_frames = HeadlessPort.frame_count(ctx.port)

    assert initial_frames > 0
    assert String.contains?(screen_row(ctx, 1), "hello")

    send_key(ctx, ?i)

    assert editor_mode(ctx) == :insert
    assert HeadlessPort.frame_count(ctx.port) > initial_frames
  end
end
