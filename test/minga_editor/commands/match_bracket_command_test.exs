defmodule MingaEditor.Commands.MatchBracketCommandTest do
  @moduledoc """
  Command-level coverage for `:match_bracket`.

  Uses the real parser Port so the command path gets direct match-found and no-match evidence without booting the full editor UI.
  """

  # Starts the real parser Port under its global production name, so these tests must not run concurrently.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Parser.Manager, as: ParserManager
  alias MingaEditor.Commands.Movement
  alias MingaEditor.HighlightSync
  alias MingaEditor.RenderPipeline.TestHelpers

  @moduletag timeout: 15_000

  setup do
    if Process.whereis(Minga.Parser.Manager) == nil do
      start_supervised!({ParserManager, []})
    end

    :ok
  end

  describe ":match_bracket command path" do
    test "jumps from an opening delimiter to the matching end" do
      {state, buffer} = prepared_state("def foo do\n  :ok\nend\n", :elixir)
      BufferProcess.move_to(buffer, {0, 0})

      _ = Movement.execute(state, :match_bracket)

      assert BufferProcess.cursor(buffer) == {2, 0}
    end

    test "is a no-op when the parser has no matching item" do
      {state, buffer} = prepared_state("word\n", :elixir)
      BufferProcess.move_to(buffer, {0, 0})

      _ = Movement.execute(state, :match_bracket)

      assert BufferProcess.cursor(buffer) == {0, 0}
    end
  end

  defp prepared_state(content, filetype) do
    state = TestHelpers.base_state(content: content, filetype: filetype)
    {HighlightSync.setup_for_buffer(state), state.workspace.buffers.active}
  end
end
