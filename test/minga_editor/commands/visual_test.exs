defmodule MingaEditor.Commands.VisualTest do
  @moduledoc """
  Split visual coverage by layer.

  Mode FSM tests assert key emission. Command-state tests assert buffer/register behavior without a live Editor GenServer.
  """

  use ExUnit.Case, async: true

  import MingaEditor.CommandStateHelpers

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Mode
  alias MingaEditor.Commands.Visual

  describe "Layer 0 Mode FSM: visual key emission" do
    test "v enters characterwise visual mode" do
      {mode, commands, mode_state} = Mode.process(:normal, {?v, 0}, Mode.initial_state())

      assert mode == :visual
      assert commands == []
      assert mode_state.visual_type == :char
    end

    test "V enters linewise visual mode" do
      {mode, commands, mode_state} = Mode.process(:normal, {?V, 0}, Mode.initial_state())

      assert mode == :visual
      assert commands == []
      assert mode_state.visual_type == :line
    end

    test "visual d and y emit command outputs and leave visual mode" do
      {_mode, _commands, mode_state} = Mode.process(:normal, {?v, 0}, Mode.initial_state())

      assert {:normal, [:delete_visual_selection], _} = Mode.process(:visual, {?d, 0}, mode_state)
      assert {:normal, [:yank_visual_selection], _} = Mode.process(:visual, {?y, 0}, mode_state)
    end
  end

  describe "Layer 0/1 command state: visual selection behavior" do
    test "delete_visual_selection deletes characterwise selection and stores unnamed register" do
      buffer = start_buffer("hello world")
      BufferProcess.move_to(buffer, {0, 2})
      state = command_state(buffer) |> with_visual_selection({0, 0}, :char)

      state = Visual.execute(state, :delete_visual_selection)

      assert BufferProcess.content(buffer) == "lo world"
      assert register_entry(state) == {"hel", :charwise}
    end

    test "delete_visual_selection deletes linewise selection" do
      buffer = start_buffer("hello\nworld\nfoo")
      BufferProcess.move_to(buffer, {1, 0})
      state = command_state(buffer) |> with_visual_selection({0, 0}, :line)

      state = Visual.execute(state, :delete_visual_selection)

      assert BufferProcess.content(buffer) == "foo"
      assert register_entry(state) == {"hello\nworld\n", :linewise}
    end

    test "yank_visual_selection leaves content unchanged and stores the selection" do
      buffer = start_buffer("hello world")
      BufferProcess.move_to(buffer, {0, 2})
      state = command_state(buffer) |> with_visual_selection({0, 0}, :char)

      state = Visual.execute(state, :yank_visual_selection)

      assert BufferProcess.content(buffer) == "hello world"
      assert register_entry(state) == {"hel", :charwise}
      assert register_entry(state, "0") == {"hel", :charwise}
    end
  end
end
