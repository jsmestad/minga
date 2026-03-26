defmodule Minga.Editor.Commands.MinibufferTest do
  @moduledoc """
  Tests for the :accept_command_candidate command handler.

  Verifies that Tab acceptance in command mode replaces the input with
  the selected candidate, handles edge cases (no match, wrong mode),
  and resets the candidate_index after acceptance.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor

  defp start_editor(content \\ "hello") do
    {:ok, buffer} = BufferServer.start_link(content: content)

    {:ok, editor} =
      Editor.start_link(
        name: :"editor_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        buffer: buffer,
        width: 80,
        height: 24
      )

    {editor, buffer}
  end

  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    _ = :sys.get_state(editor)
  end

  defp get_mode_state(editor) do
    state = :sys.get_state(editor)
    {state.workspace.editing.mode, state.workspace.editing.mode_state}
  end

  describe "accept_command_candidate via Tab in command mode" do
    test "Tab replaces input with selected candidate" do
      {editor, _buf} = start_editor()

      # Enter command mode
      send_key(editor, ?:)
      # Type "sav" to get "save" as a candidate
      send_key(editor, ?s)
      send_key(editor, ?a)
      send_key(editor, ?v)

      # Press Tab to accept
      send_key(editor, 9)

      {mode, ms} = get_mode_state(editor)
      assert mode == :command
      assert ms.input == "save"
      assert ms.candidate_index == 0
    end

    test "Tab with no matching candidates is a no-op" do
      {editor, _buf} = start_editor()

      # Enter command mode
      send_key(editor, ?:)
      # Type nonsense that matches nothing
      send_key(editor, ?z)
      send_key(editor, ?z)
      send_key(editor, ?z)
      send_key(editor, ?z)
      send_key(editor, ?z)

      # Press Tab
      send_key(editor, 9)

      {mode, ms} = get_mode_state(editor)
      assert mode == :command
      assert ms.input == "zzzzz"
    end

    test "arrow down then Tab selects second candidate" do
      {editor, _buf} = start_editor()

      # Enter command mode
      send_key(editor, ?:)
      # Type "qui" to get "quit" and "quit_all" as candidates
      send_key(editor, ?q)
      send_key(editor, ?u)
      send_key(editor, ?i)

      # Arrow down to select second candidate
      send_key(editor, 57_353)

      # Press Tab to accept
      send_key(editor, 9)

      {mode, ms} = get_mode_state(editor)
      assert mode == :command
      # Should have accepted the second candidate (quit_all)
      assert ms.input == "quit_all"
      assert ms.candidate_index == 0
    end
  end
end
