defmodule MingaEditor.Renderer.FrameAttemptTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.Renderer.FrameAttempt
  alias MingaEditor.State.Windows

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

  test "latest refreshes nil or older pending with fallback identity" do
    fallback = FrameAttempt.new(intent(), 12, 20)

    from_nil = FrameAttempt.latest(nil, fallback)
    from_older = FrameAttempt.latest(FrameAttempt.new(intent(), 11, 10), fallback)

    assert from_nil.intent == fallback.intent
    assert from_nil.pushed_at == 20
    assert from_nil.seq > 12

    assert from_older.intent == fallback.intent
    assert from_older.pushed_at == 20
    assert from_older.seq > 12
  end

  defp intent do
    %Input{
      port_manager: self(),
      theme: :theme,
      capabilities: %Capabilities{},
      shell_id: :traditional,
      shell: MingaEditor.Shell.Traditional,
      workspace: %{windows: %Windows{}}
    }
    |> Intent.from_input()
  end
end
