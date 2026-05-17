defmodule MingaEditor.Commands.MinibufferTest do
  @moduledoc """
  Tests for the :accept_command_candidate command handler.

  Most coverage exercises command-mode state transitions directly. One editor-level smoke test remains to verify that Tab is routed to the command handler from command mode.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options
  alias MingaEditor
  alias MingaEditor.Commands
  alias MingaEditor.Editing
  alias MingaEditor.Startup
  alias MingaEditor.State, as: EditorState

  @sync_timeout 30_000

  defp start_editor(content \\ "hello") do
    {:ok, buffer} = BufferProcess.start_link(content: content)

    {:ok, editor} =
      MingaEditor.start_link(
        name: :"editor_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        buffer: buffer,
        width: 80,
        height: 24,
        editing_model: :vim
      )

    {editor, buffer}
  end

  defp start_command_state(input, candidate_index \\ 0) do
    {:ok, buffer} = BufferProcess.start_link(content: "hello")
    {:ok, options} = Options.start_link(name: nil)

    state =
      Startup.build_initial_state(
        port_manager: nil,
        options_server: options,
        buffer: buffer,
        width: 80,
        height: 24,
        editing_model: :vim
      )
      |> EditorState.transition_mode(:command)
      |> Editing.update_mode_state(%{input: input, candidate_index: candidate_index})

    {state, buffer}
  end

  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    :sys.get_state(editor, @sync_timeout)
  end

  describe "accept_command_candidate command state" do
    @describetag layer: :command_state

    test "replaces input with selected candidate" do
      {state, _buffer} = start_command_state("sav")

      result = Commands.execute(state, {:accept_command_candidate})
      mode_state = Editing.mode_state(result)

      assert Minga.Editing.mode(result) == :command
      assert mode_state.input == "save"
      assert mode_state.candidate_index == 0
    end

    test "with no matching candidates is a no-op" do
      {state, _buffer} = start_command_state("zzzzz")

      result = Commands.execute(state, {:accept_command_candidate})
      mode_state = Editing.mode_state(result)

      assert Minga.Editing.mode(result) == :command
      assert mode_state.input == "zzzzz"
      assert mode_state.candidate_index == 0
    end

    test "accepts the selected non-first candidate" do
      {state, _buffer} = start_command_state("qui", 1)

      result = Commands.execute(state, {:accept_command_candidate})
      mode_state = Editing.mode_state(result)

      assert mode_state.input == "quit_all"
      assert mode_state.candidate_index == 0
    end

    test "does nothing outside command mode" do
      {state, _buffer} = start_command_state("sav")
      state = EditorState.transition_mode(state, :normal)

      result = Commands.execute(state, {:accept_command_candidate})

      assert Minga.Editing.mode(result) == :normal
    end
  end

  describe "accept_command_candidate editor integration smoke" do
    @describetag layer: :editor_integration

    test "Tab routes to quit_all candidate acceptance in command mode" do
      {editor, _buf} = start_editor()

      send_key(editor, ?:)
      send_key(editor, ?q)
      send_key(editor, ?u)
      send_key(editor, ?i)

      _ = send_key(editor, 57_353)
      state = send_key(editor, 9)
      mode_state = Editing.mode_state(state)

      assert Minga.Editing.mode(state) == :command
      assert mode_state.input == "quit_all"
      assert mode_state.candidate_index == 0
    end
  end
end
