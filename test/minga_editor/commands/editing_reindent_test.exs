defmodule MingaEditor.Commands.EditingReindentTest do
  @moduledoc """
  Reindent coverage at the mode FSM and direct command-state layers.
  """

  use ExUnit.Case, async: true

  import MingaEditor.CommandStateHelpers

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Mode
  alias Minga.Mode.OperatorPending
  alias Minga.Mode.OperatorPendingState
  alias MingaEditor.Commands.Editing

  describe "Layer 0 Mode FSM: = operator dispatch" do
    test "first = enters operator-pending with :reindent" do
      {mode, commands, mode_state} = Mode.process(:normal, {?=, 0}, Mode.initial_state())

      assert mode == :operator_pending
      assert commands == []
      assert mode_state.operator == :reindent
    end

    test "== emits current-line reindent and returns to normal" do
      state = %OperatorPendingState{operator: :reindent, op_count: 1}

      assert {:execute_then_transition, [{:reindent_lines, 1}], :normal, _} =
               OperatorPending.handle_key({?=, 0}, state)
    end

    test "=w, =G, and =gg emit motion reindent and return to normal" do
      state = %OperatorPendingState{operator: :reindent, op_count: 1}

      assert {:execute_then_transition, [{:reindent_motion, :word_forward}], :normal, _} =
               OperatorPending.handle_key({?w, 0}, state)

      assert {:execute_then_transition, [{:reindent_motion, :document_end}], :normal, _} =
               OperatorPending.handle_key({?G, 0}, state)

      pending_g = %OperatorPendingState{operator: :reindent, op_count: 1, pending_g: true}

      assert {:execute_then_transition, [{:reindent_motion, :document_start}], :normal, _} =
               OperatorPending.handle_key({?g, 0}, pending_g)
    end

    test "visual = emits visual reindent and returns to normal" do
      {_mode, _commands, mode_state} = Mode.process(:normal, {?V, 0}, Mode.initial_state())

      assert {:normal, [:reindent_visual_selection], _} =
               Mode.process(:visual, {?=, 0}, mode_state)
    end

    test "=iw emits text-object reindent and returns to normal" do
      state = %OperatorPendingState{
        operator: :reindent,
        op_count: 1,
        text_object_modifier: :inner
      }

      assert {:execute_then_transition, [{:reindent_text_object, :inner, :word}], :normal, _} =
               OperatorPending.handle_key({?w, 0}, state)
    end
  end

  describe "configured parser manager routing" do
    test "newline indentation queries the manager stored in editor state" do
      test_pid = self()
      manager = spawn_link(fn -> parser_manager_loop(test_pid) end)
      on_exit(fn -> send(manager, :stop) end)
      buffer = start_buffer("def foo do")
      BufferProcess.move_to(buffer, {0, 10})
      state = %{command_state(buffer) | parser_manager: manager}

      _state = Editing.execute(state, :insert_newline)

      assert_receive {:parser_request, {:request_indent, ^buffer, 1, 200}}
      assert BufferProcess.content(buffer) == "def foo do\n      "
    end
  end

  describe "Layer 0/1 command state: reindent content behavior" do
    test "reindent_lines applies exact copy-indent fallback to the current line" do
      buffer = start_buffer("  parent\nchild")
      BufferProcess.move_to(buffer, {1, 0})
      state = command_state(buffer)

      _state = Editing.execute(state, {:reindent_lines, 1})

      assert BufferProcess.content(buffer) == "  parent\n  child"
    end

    test "reindent_lines preserves exact content when no indentation is needed" do
      buffer = start_buffer("hello\nworld\nfoo")
      state = command_state(buffer)

      _state = Editing.execute(state, {:reindent_lines, 1})

      assert BufferProcess.content(buffer) == "hello\nworld\nfoo"
    end

    test "reindent_motion handles multi-line range with exact output" do
      buffer = start_buffer("  parent\nchild\nleaf")
      state = command_state(buffer)

      _state = Editing.execute(state, {:reindent_motion, :document_end})

      assert BufferProcess.content(buffer) == "parent\nchild\nleaf"
    end

    test "reindent_visual_selection handles selected line ranges with exact output" do
      buffer = start_buffer("  parent\nchild\nleaf")
      BufferProcess.move_to(buffer, {1, 0})
      state = command_state(buffer) |> with_visual_selection({0, 0}, :line)

      _state = Editing.execute(state, :reindent_visual_selection)

      assert BufferProcess.content(buffer) == "parent\nchild\nleaf"
    end
  end

  defp parser_manager_loop(test_pid) do
    receive do
      {:"$gen_call", from, request} ->
        send(test_pid, {:parser_request, request})
        GenServer.reply(from, 3)
        parser_manager_loop(test_pid)

      :stop ->
        :ok
    end
  end
end
