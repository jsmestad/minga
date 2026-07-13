defmodule MingaEditor.UI.PrettifySymbolsEffectTest do
  @moduledoc "Behavior tests for Buffer-keyed latest-wins prettification."

  use ExUnit.Case, async: true

  alias MingaEditor.Effect.Outcome
  alias MingaEditor.UI.Highlight
  alias MingaEditor.UI.PrettifySymbolsEffect

  import MingaEditor.RenderPipeline.TestHelpers

  test "request uses Buffer identity, latest-wins policy, and immutable parser input" do
    buffer = fake_buffer()

    highlight =
      Highlight.new()
      |> Highlight.put_names(["operator"])
      |> Highlight.put_spans(7, [%{start_byte: 0, end_byte: 2, capture_id: 0}])

    request = PrettifySymbolsEffect.request(buffer, highlight, :elixir)

    assert request.resource == {:prettify_symbols, buffer}
    assert request.policy.mode == :latest_wins
    assert request.policy.max_queued == 0
    assert request.effect.highlight == highlight
    assert request.effect.filetype == :elixir
  end

  test "completed, failed, stale, and canceled outcomes do not mutate EditorState" do
    buffer = fake_buffer()
    request = PrettifySymbolsEffect.request(buffer, Highlight.new(), :text)
    state = base_state()

    outcomes = [
      Outcome.completed(request, :applied),
      Outcome.failed(request, :buffer_closed),
      Outcome.stale(Outcome.completed(request, :applied), :superseded),
      Outcome.canceled(request, :superseded)
    ]

    Enum.each(outcomes, fn outcome ->
      assert {^state, ^outcome} = PrettifySymbolsEffect.apply(state, outcome)
      refute PrettifySymbolsEffect.render?(outcome)
    end)
  end

  defp fake_buffer do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(pid, :stop) end)
    pid
  end
end
