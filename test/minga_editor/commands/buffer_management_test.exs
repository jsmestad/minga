defmodule MingaEditor.Commands.BufferManagementTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Command
  alias Minga.Config.Options
  alias MingaEditor
  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.Startup
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.TabBar

  @sync_timeout 30_000

  defp start_editor(content) do
    {:ok, buffer} = BufferProcess.start_link(content: content)
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

  defp start_command_state(content) do
    {:ok, buffer} = BufferProcess.start_link(content: content)
    {:ok, options} = Options.start_link(name: nil)

    state =
      Startup.build_initial_state(
        port_manager: nil,
        options_server: options,
        buffer: buffer,
        width: 40,
        height: 10,
        editing_model: :vim
      )

    {state, buffer}
  end

  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    _ = :sys.get_state(editor, @sync_timeout)
  end

  defp type_string(editor, text) do
    text
    |> String.to_charlist()
    |> Enum.each(fn char -> send_key(editor, char) end)
  end

  defp add_file_tab(state, label) do
    {:ok, buffer} = BufferProcess.start_link(content: "#{label} content")
    state = EditorState.add_buffer(state, buffer, context: :open)
    state
  end

  defp add_file_tab_with_buffer(state), do: add_file_tab_with_buffer(state, "second.txt")

  defp add_file_tab_with_buffer(state, label) do
    {:ok, buffer} = BufferProcess.start_link(content: "#{label} content")
    state = EditorState.add_buffer(state, buffer, context: :open)
    {state, buffer}
  end

  defp tab_count(state), do: state |> EditorState.tab_bar() |> TabBar.count()

  describe "__commands__/0" do
    test "preserves line toggle and wrap metadata" do
      commands = BufferManagement.__commands__() |> Map.new(&{&1.name, &1})

      assert %Command{requires_buffer: true, option_toggle: {:line_numbers, toggle}} =
               commands[:cycle_line_numbers]

      assert is_function(toggle, 1)
      assert toggle.(:hybrid) == :absolute
      assert toggle.(:absolute) == :relative
      assert toggle.(:relative) == :none
      assert toggle.(:none) == :hybrid

      assert %Command{requires_buffer: true, option_toggle: :wrap} = commands[:toggle_wrap]

      assert %Command{requires_buffer: true, option_toggle: :show_invisible} =
               commands[:toggle_invisible]
    end
  end

  describe "command mode editor integration smoke" do
    @describetag layer: :editor_integration

    test ": enters command mode, typing w and Enter saves" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "editor_test_save_#{:erlang.unique_integer([:positive])}.txt")
      File.write!(path, "test content")
      on_exit(fn -> File.rm(path) end)

      {:ok, buffer} = BufferProcess.start_link(file_path: path)
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
      _ = :sys.get_state(editor, @sync_timeout)

      assert File.read!(path) == "test content"
    end

    test ":e command keeps the editor process alive when opening an arbitrary path" do
      {editor, _buffer} = start_editor("hello")
      send_key(editor, ?:)
      type_string(editor, "e test.txt")
      send_key(editor, 13)

      assert Process.alive?(editor)
    end

    test "goto line via :N command moves the buffer cursor" do
      {editor, buffer} = start_editor("line1\nline2\nline3\nline4")
      send_key(editor, ?:)
      send_key(editor, ?3)
      send_key(editor, 13)
      _ = :sys.get_state(editor, @sync_timeout)

      {line, _col} = BufferProcess.cursor(buffer)
      assert line == 2
    end

    test "unknown ex command is a no-op at the editor layer" do
      {editor, buffer} = start_editor("hello")
      before = BufferProcess.content(buffer)

      send_key(editor, ?:)
      type_string(editor, "nonexistent")
      send_key(editor, 13)

      assert BufferProcess.content(buffer) == before
      assert Process.alive?(editor)
    end
  end

  describe "global keybinding editor integration smoke" do
    @describetag layer: :editor_integration

    test "Ctrl+S saves the buffer" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "editor_ctrl_s_#{:erlang.unique_integer([:positive])}.txt")
      File.write!(path, "ctrl-s test")
      on_exit(fn -> File.rm(path) end)

      {:ok, buffer} = BufferProcess.start_link(file_path: path)
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
      _ = :sys.get_state(editor, @sync_timeout)

      assert File.read!(path) == "ctrl-s test"
    end

    test "Ctrl+S with startup-created fallback buffer keeps the editor alive" do
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

  describe "tab-aware quit command state" do
    @describetag layer: :command_state

    test ":q with multiple tabs closes the current tab without requesting process shutdown" do
      {state, _buffer} = start_command_state("first file")
      {state, closed_tab_buffer} = add_file_tab_with_buffer(state)
      closed_tab_id = EditorState.tab_bar(state).active_id
      assert tab_count(state) == 2

      result = BufferManagement.execute(state, {:execute_ex_command, {:quit, []}})

      remaining_tab_ids =
        result |> EditorState.tab_bar() |> Map.fetch!(:tabs) |> Enum.map(& &1.id)

      assert tab_count(result) == 1
      refute closed_tab_id in remaining_tab_ids
      assert Process.alive?(closed_tab_buffer)
    end

    test ":q with a single tab leaves an empty editor buffer open" do
      {state, _buffer} = start_command_state("first file")

      result = BufferManagement.execute(state, {:execute_ex_command, {:quit, []}})

      assert tab_count(result) == 1
      assert BufferProcess.content(result.workspace.buffers.active) == ""
    end

    test ":q does not kill the closed tab buffer" do
      {state, _first_buffer} = start_command_state("first file")
      {state, closed_tab_buffer} = add_file_tab_with_buffer(state)

      result = BufferManagement.execute(state, {:execute_ex_command, {:quit, []}})

      assert tab_count(result) == 1
      assert Process.alive?(closed_tab_buffer)
    end
  end

  describe "close_other_tabs command state" do
    @describetag layer: :command_state

    test "closes all tabs except the active tab" do
      {state, _buffer} = start_command_state("first file")
      original_tab_id = EditorState.tab_bar(state).active_id

      state =
        state
        |> add_file_tab("second.txt")
        |> add_file_tab("third.txt")

      active_tab_id = EditorState.tab_bar(state).active_id
      assert tab_count(state) == 3

      result = BufferManagement.execute(state, :close_other_tabs)

      remaining_tab_ids =
        result |> EditorState.tab_bar() |> Map.fetch!(:tabs) |> Enum.map(& &1.id)

      assert tab_count(result) == 1
      assert EditorState.tab_bar(result).active_id == active_tab_id
      refute original_tab_id in remaining_tab_ids
    end

    test "ignores stopped-session events for tabs that were already removed" do
      {state, _buffer} = start_command_state("first file")

      state =
        EditorState.update_shell_state(state, fn shell_state ->
          %{shell_state | agent: AgentState.set_error(%AgentState{}, "active agent")}
        end)

      result = BufferManagement.handle_agent_session_down(state, self(), :normal)

      assert AgentState.status(result.shell_state.agent) == :error
      assert result.shell_state.agent.error == "active agent"
    end
  end

  describe "dirty quit confirmation command state" do
    @describetag layer: :command_state

    test "quit with dirty buffer sets a confirmation prompt" do
      {state, buffer} = start_command_state("hello")
      BufferProcess.insert_char(buffer, "X")
      assert BufferProcess.dirty?(buffer)

      result = BufferManagement.execute(state, {:execute_ex_command, {:quit, []}})

      assert result.pending_quit == :quit
      assert result.shell_state.status_msg =~ "Modified buffers"
    end

    test "n at confirmation prompt cancels quit" do
      {state, buffer} = start_command_state("hello")
      BufferProcess.insert_char(buffer, "X")

      state = BufferManagement.execute(state, {:execute_ex_command, {:quit, []}})
      assert state.pending_quit == :quit

      result = BufferManagement.execute(state, :confirm_quit_no)

      assert result.pending_quit == nil
      assert result.shell_state.status_msg == nil
    end
  end

  describe "dirty quit confirmation editor integration smoke" do
    @describetag layer: :editor_integration

    test "Escape at confirmation prompt cancels quit through the input router" do
      {editor, buffer} = start_editor("hello")
      BufferProcess.insert_char(buffer, "X")

      type_string(editor, ":q\r")
      state = :sys.get_state(editor, @sync_timeout)
      assert state.pending_quit == :quit

      send_key(editor, 27)
      state = :sys.get_state(editor, @sync_timeout)
      assert state.pending_quit == nil
    end
  end
end
