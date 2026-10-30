defmodule MingaEditor.Renderer.FrameAttemptTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Renderer.FrameAttempt
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.TestHelpers

  test "new stores exact attempt identity" do
    intent = intent()

    assert %FrameAttempt{intent: ^intent, seq: 12, pushed_at: 34} =
             FrameAttempt.new(intent, 12, 34)
  end

  test "force_keyframe changes only the intent keyframe flag" do
    attempt = FrameAttempt.new(intent(), 12, 34)

    forced = FrameAttempt.force_keyframe(attempt)

    assert forced.seq == 12
    assert forced.pushed_at == 34
    assert forced.intent.frame.force_keyframe?
    refute attempt.intent.frame.force_keyframe?
  end

  test "latest returns newer pending attempt unchanged" do
    pending = FrameAttempt.new(intent(), 13, 30)
    fallback = FrameAttempt.new(intent(), 12, 20)

    assert FrameAttempt.latest(pending, fallback) == pending
  end

  test "latest selects the fallback without assigning a new wire identity" do
    fallback = FrameAttempt.new(intent(), 12, 20)

    from_nil = FrameAttempt.latest(nil, fallback)
    from_older = FrameAttempt.latest(FrameAttempt.new(intent(), 11, 10), fallback)

    assert from_nil == fallback
    assert from_older == fallback
  end

  defp intent do
    TestHelpers.base_state()
    |> Input.from_editor_state()
    |> Map.fetch!(:intent)
  end
end
