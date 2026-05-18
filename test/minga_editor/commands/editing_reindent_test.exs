defmodule MingaEditor.Commands.EditingReindentTest do
  @moduledoc """
  Split reindent coverage by layer.

  Mode FSM tests assert `=` dispatch. Command-state tests assert indentation effects without a live Editor GenServer. One editor smoke test keeps the event-bus prompt regression covered.
  """

  use ExUnit.Case, async: true

  import MingaEditor.CommandStateHelpers

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Mode
  alias Minga.Mode.OperatorPending
  alias Minga.Mode.OperatorPendingState
  alias MingaEditor
  alias MingaEditor.Commands.Editing

  @sync_timeout 15_000

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

  describe "Editor GenServer smoke: reindent event routing" do
    test "== routes through a live editor and applies reindent" do
      {editor, buffer, _events_registry} = start_editor("  parent\nchild")
      BufferProcess.move_to(buffer, {1, 0})

      send_key(editor, ?=)
      send_key(editor, ?=)

      assert BufferProcess.content(buffer) == "  parent\n  child"
      assert sync_editor(editor) == :normal
    end

    test "default bus tool prompts cannot interrupt reindent dispatch" do
      {editor, _buffer, events_registry} = start_editor("hello world")

      refute editor in Minga.Events.subscribers(:tool_missing)
      assert editor in Minga.Events.subscribers(:tool_missing, events_registry)

      Minga.Events.broadcast(:tool_missing, %Minga.Events.ToolMissingEvent{command: "rg"})

      assert sync_editor(editor) == :normal
    end
  end

  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    _ = sync_editor(editor)
  end

  defp sync_editor(editor), do: GenServer.call(editor, :api_mode, @sync_timeout)

  defp start_editor(content) do
    id = :erlang.unique_integer([:positive])
    events_registry = :"reindent_events_#{id}"
    start_supervised!({Minga.Events, name: events_registry})

    {:ok, buffer} = BufferProcess.start_link(content: content, events_registry: events_registry)

    {:ok, editor} =
      MingaEditor.start_link(
        name: :"reindent_editor_#{id}",
        port_manager: nil,
        buffer: buffer,
        width: 80,
        height: 24,
        editing_model: :vim,
        events_registry: events_registry,
        suppress_tool_prompts: true
      )

    {editor, buffer, events_registry}
  end
end
