defmodule MingaEditor.Commands.MatchBracketCommandTest do
  @moduledoc """
  Command-level coverage for `:match_bracket`.

  Uses the real parser Port so the command path gets direct match-found and no-match evidence without booting the full editor UI.
  """

  # Starts the real parser Port under its global production name, so these tests must not run concurrently.
  use ExUnit.Case, async: false

  @moduletag :heavy

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Parser.EventCorrelation
  alias Minga.Parser.Manager, as: ParserManager
  alias MingaEditor.Commands.Helpers
  alias MingaEditor.Commands.Movement
  alias MingaEditor.HighlightSync
  alias MingaEditor.RenderPipeline.TestHelpers

  @moduletag timeout: 15_000
  @sync_timeout 15_000

  setup do
    if Process.whereis(Minga.Parser.Manager) == nil do
      start_supervised!({ParserManager, []})
    end

    :ok = ParserManager.subscribe()
    :ok
  end

  describe ":match_bracket command path" do
    test "jumps from an opening delimiter to the matching end and marks the window" do
      {state, buffer} = prepared_state("def foo do\n  :ok\nend\n", :elixir)
      BufferProcess.move_to(buffer, {0, 0})

      updated = Movement.execute(state, :match_bracket)

      assert BufferProcess.cursor(buffer) == {2, 0}
      # A successful bracket jump is authoritative (#2652): it must discard a
      # frontend-held local offset even when it lands on the same committed top.
      assert authoritative_seq(updated) == 1
    end

    test "uses the parser manager stored in editor state" do
      test_pid = self()
      manager = spawn_link(fn -> parser_manager_loop(test_pid, make_ref()) end)
      on_exit(fn -> send(manager, :stop) end)
      state = TestHelpers.base_state(content: "(x)", filetype: :elixir)
      buffer = state.workspace.buffers.active
      state = %{state | parser_manager: manager}

      _updated = Movement.execute(state, :match_bracket)

      assert_receive {:parser_request, {:request_match_item, ^buffer, 0, 0, 2_000}}
      assert BufferProcess.cursor(buffer) == {0, 2}
    end

    test "operator-pending bracket motion uses the parser manager stored in editor state" do
      test_pid = self()
      manager = spawn_link(fn -> parser_manager_loop(test_pid, make_ref()) end)
      on_exit(fn -> send(manager, :stop) end)
      state = TestHelpers.base_state(content: "(x)", filetype: :elixir)
      buffer = state.workspace.buffers.active
      state = %{state | parser_manager: manager}

      _updated = Helpers.apply_operator_motion(buffer, state, :match_bracket, :delete)

      assert_receive {:parser_request, {:request_match_item, ^buffer, 0, 0, 2_000}}
      assert BufferProcess.content(buffer) == ""
    end

    test "is a no-op when the parser has no matching item" do
      {state, buffer} = prepared_state("word\n", :elixir)
      BufferProcess.move_to(buffer, {0, 0})

      updated = Movement.execute(state, :match_bracket)

      assert BufferProcess.cursor(buffer) == {0, 0}
      # No bracket, no jump: the marker must stay untouched so the no-op never
      # discards the user's local scroll (#2652).
      assert authoritative_seq(updated) == 0
    end
  end

  defp prepared_state(content, filetype) do
    state = TestHelpers.base_state(content: content, filetype: filetype)
    buffer = state.workspace.buffers.active
    state = HighlightSync.setup_for_buffer(state)

    assert_receive {:minga_highlight,
                    {:buffer_event, ^buffer, _correlation, {:highlight_spans, _spans}}},
                   @sync_timeout

    {state, buffer}
  end

  defp parser_manager_loop(test_pid, generation) do
    receive do
      {:"$gen_call", from, {:register_buffer_correlated, _buffer, _config}} ->
        GenServer.reply(from, EventCorrelation.new(generation, 0))
        parser_manager_loop(test_pid, generation)

      {:"$gen_call", from, request = {:request_match_item, _buffer, _row, _col, _timeout}} ->
        send(test_pid, {:parser_request, request})
        GenServer.reply(from, {0, 2})
        parser_manager_loop(test_pid, generation)

      :stop ->
        :ok
    end
  end

  defp authoritative_seq(state) do
    win_id = state.workspace.windows.active

    MingaEditor.Window.authoritative_scroll_seq(state.workspace.windows.map[win_id])
  end
end
