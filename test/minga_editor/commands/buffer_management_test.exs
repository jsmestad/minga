defmodule MingaEditor.Commands.BufferManagementTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Config.Options
  alias MingaEditor
  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.TabBar

  defp start_editor(content) do
    {:ok, buffer} = BufferServer.start_link(content: content)
    {:ok, options} = Options.start_link(name: nil)

    {:ok, editor} =
      MingaEditor.start_link(
        name: :"editor_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        options_server: options,
        buffer: buffer,
        width: 40,
        height: 10,
        editing_model: :vim
      )

    {editor, buffer}
  end

  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    _ = :sys.get_state(editor)
  end

  defp type_string(editor, text) do
    text
    |> String.to_charlist()
    |> Enum.each(fn char -> send_key(editor, char) end)
  end

  defp tab_count(editor) do
    state = :sys.get_state(editor)
    TabBar.count(state.shell_state.tab_bar)
  end

  describe "command mode" do
    test ": enters command mode, typing w and Enter saves" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "editor_test_save_#{:erlang.unique_integer([:positive])}.txt")
      File.write!(path, "test content")

      {:ok, buffer} = BufferServer.start_link(file_path: path)

      {:ok, options} = Options.start_link(name: nil)

      {:ok, editor} =
        MingaEditor.start_link(
          name: :"editor_cmd_#{:erlang.unique_integer([:positive])}",
          port_manager: nil,
          options_server: options,
          buffer: buffer,
          width: 40,
          height: 10,
          editing_model: :vim
        )

      send_key(editor, ?:)
      send_key(editor, ?w)
      send_key(editor, 13)
      _ = :sys.get_state(editor)

      assert File.exists?(path)
      assert File.read!(path) == "test content"

      File.rm(path)
    end

    test ":e command doesn't crash" do
      {editor, _buffer} = start_editor("hello")
      send_key(editor, ?:)
      type_string(editor, "e test.txt")
      send_key(editor, 13)

      assert Process.alive?(editor)
    end

    test "goto line via :N command" do
      {editor, buffer} = start_editor("line1\nline2\nline3\nline4")
      send_key(editor, ?:)
      send_key(editor, ?3)
      send_key(editor, 13)
      _ = :sys.get_state(editor)

      {line, _col} = BufferServer.cursor(buffer)
      assert line == 2
    end

    test "unknown ex command doesn't crash" do
      {editor, _buffer} = start_editor("hello")
      send_key(editor, ?:)
      type_string(editor, "nonexistent")
      send_key(editor, 13)

      assert Process.alive?(editor)
    end
  end

  describe "global keybindings" do
    test "Ctrl+S saves the buffer" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "editor_ctrl_s_#{:erlang.unique_integer([:positive])}.txt")
      File.write!(path, "ctrl-s test")

      {:ok, buffer} = BufferServer.start_link(file_path: path)

      {:ok, options} = Options.start_link(name: nil)

      {:ok, editor} =
        MingaEditor.start_link(
          name: :"editor_ctrls_#{:erlang.unique_integer([:positive])}",
          port_manager: nil,
          options_server: options,
          buffer: buffer,
          width: 40,
          height: 10,
          editing_model: :vim
        )

      send_key(editor, ?s, 0x02)
      _ = :sys.get_state(editor)

      assert File.exists?(path)
      assert File.read!(path) == "ctrl-s test"

      File.rm(path)
    end

    test "Ctrl+S with no buffer doesn't crash" do
      {:ok, editor} =
        MingaEditor.start_link(
          name: :"editor_#{:erlang.unique_integer([:positive])}",
          port_manager: nil,
          buffer: nil,
          width: 40,
          height: 10,
          editing_model: :vim
        )

      send_key(editor, ?s, 0x02)
      assert Process.alive?(editor)
    end
  end

  describe "tab-aware :q" do
    test ":q with multiple tabs closes the current tab without exiting" do
      {editor, _buffer} = start_editor("first file")
      assert tab_count(editor) == 1

      # Opening a second file on a file tab adds to the same tab's buffer
      # list (no new tab). To get 2 tabs, inject a second tab directly.
      add_second_tab(editor)
      assert tab_count(editor) == 2

      # Type :q<Enter>
      send_key(editor, ?:)
      type_string(editor, "q")
      send_key(editor, 13)

      assert Process.alive?(editor), "Editor should stay alive when closing one of multiple tabs"
      assert tab_count(editor) == 1
    end

    test ":q with a single tab leaves an empty editor open" do
      {editor, _buffer} = start_editor("first file")

      type_string(editor, ":q\r")

      state = :sys.get_state(editor)
      assert Process.alive?(editor)
      assert tab_count(editor) == 1
      assert BufferServer.content(state.workspace.buffers.active) == ""
    end

    test ":q does not kill the buffer (matches Neovim)" do
      {editor, first_buffer} = start_editor("first file")
      add_second_tab(editor)
      assert tab_count(editor) == 2

      # Type :q<Enter> to close the current tab
      send_key(editor, ?:)
      type_string(editor, "q")
      send_key(editor, 13)

      # The first buffer should still be alive (not killed)
      assert Process.alive?(first_buffer),
             "Buffer should stay alive after :q closes its tab"
    end
  end

  # Injects a second file tab into the editor's tab bar by manipulating
  # state directly. This avoids needing to go through the full open_file
  # path which adds buffers to the existing tab rather than creating new ones.
  defp add_second_tab(editor) do
    :sys.replace_state(editor, fn state ->
      {:ok, buffer2} = BufferServer.start_link(content: "second tab content")
      {new_tb, _tab} = TabBar.add(state.shell_state.tab_bar, :file, "second.txt")
      new_buffers = Buffers.add(state.workspace.buffers, buffer2)

      MingaEditor.State.set_tab_bar(
        %{state | workspace: %{state.workspace | buffers: new_buffers}},
        new_tb
      )
    end)
  end

  describe "close_other_tabs" do
    test "closes all tabs except the active tab" do
      {editor, _buffer} = start_editor("first file")
      add_second_tab(editor)
      add_second_tab(editor)
      assert tab_count(editor) == 3

      :sys.replace_state(editor, fn state ->
        BufferManagement.execute(state, :close_other_tabs)
      end)

      state = :sys.get_state(editor)
      assert TabBar.count(state.shell_state.tab_bar) == 1
      assert TabBar.active(state.shell_state.tab_bar).label == "second.txt"
    end

    test "ignores stopped-session events for tabs that were already removed" do
      {editor, _buffer} = start_editor("first file")

      state = :sys.get_state(editor)

      state = %{
        state
        | shell_state: %{
            state.shell_state
            | agent: AgentState.set_error(%AgentState{}, "active agent")
          }
      }

      result = BufferManagement.handle_agent_session_down(state, self(), :normal)

      assert AgentState.status(result.shell_state.agent) == :error
      assert result.shell_state.agent.error == "active agent"
    end
  end

  describe "quit confirmation (#128)" do
    test "quit with dirty buffer shows confirmation prompt" do
      {editor, buffer} = start_editor("hello")

      # Make buffer dirty
      BufferServer.insert_char(buffer, "X")
      assert BufferServer.dirty?(buffer)

      # Send :q via command mode
      type_string(editor, ":q\r")
      state = :sys.get_state(editor)

      assert state.pending_quit == :quit
      assert state.shell_state.status_msg =~ "Modified buffers"
    end

    test "n at confirmation prompt cancels quit" do
      {editor, buffer} = start_editor("hello")
      BufferServer.insert_char(buffer, "X")

      type_string(editor, ":q\r")
      state = :sys.get_state(editor)
      assert state.pending_quit == :quit

      send_key(editor, ?n)
      state = :sys.get_state(editor)
      assert state.pending_quit == nil
      assert state.shell_state.status_msg == nil
    end

    test "Escape at confirmation prompt cancels quit" do
      {editor, buffer} = start_editor("hello")
      BufferServer.insert_char(buffer, "X")

      type_string(editor, ":q\r")
      state = :sys.get_state(editor)
      assert state.pending_quit == :quit

      send_key(editor, 27)
      state = :sys.get_state(editor)
      assert state.pending_quit == nil
    end
  end
end
