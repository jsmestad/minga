defmodule MingaEditor.Commands.BufferManagementTest do
  @moduledoc """
  Focused buffer-management command coverage.

  Command-state behavior is tested directly through `BufferManagement.execute/2`. The Editor GenServer tests stay as thin routing smoke checks for command-mode and global key wiring.
  """
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
  @ctrl 0x02

  describe "command metadata" do
    test "preserves option toggle metadata" do
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

  describe "command mode editor routing" do
    @tag :tmp_dir
    test ":w saves through the Editor GenServer", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "editor_test_save.txt")
      File.write!(path, "test content")
      {editor, _buffer} = start_editor(file_path: path)

      send_keys(editor, ":w\r")

      assert File.read!(path) == "test content"
    end

    @tag :tmp_dir
    test ":e opens a file using the editor options server", %{tmp_dir: tmp_dir} do
      options_server = start_supervised!({Options, name: nil})

      assert {:ok, false} =
               Options.set_for_filetype(options_server, :text, :autopair_block, false)

      path = Path.join(tmp_dir, "editor_open.txt")
      File.write!(path, "opened content")
      {editor, original_buffer} = start_editor(content: "hello", options_server: options_server)

      state = send_keys(editor, ":e #{path}\r")
      active = state.workspace.buffers.active

      assert active != original_buffer
      assert BufferProcess.file_path(active) == path
      refute BufferProcess.get_option(active, :autopair_block)
    end

    @tag :tmp_dir
    test ":e switches to an already-open file", %{tmp_dir: tmp_dir} do
      options_server = start_supervised!({Options, name: nil})

      assert {:ok, false} =
               Options.set_for_filetype(options_server, :text, :autopair_block, false)

      path = Path.join(tmp_dir, "editor_open_b.txt")
      File.write!(path, "second")
      {editor, _original_buffer} = start_editor(content: "hello", options_server: options_server)
      {:ok, existing_buffer} = MingaEditor.ensure_buffer_for_path(path, editor)

      state = send_keys(editor, ":e #{path}\r")

      assert state.workspace.buffers.active == existing_buffer
      refute BufferProcess.get_option(existing_buffer, :autopair_block)
    end

    test ":N moves the buffer cursor" do
      {editor, buffer} = start_editor(content: "line1\nline2\nline3\nline4")

      send_keys(editor, ":3\r")

      assert {2, _col} = BufferProcess.cursor(buffer)
    end
  end

  describe "global keybinding editor routing" do
    @tag :tmp_dir
    test "Ctrl+S saves file-backed buffers", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "editor_ctrl_s.txt")
      File.write!(path, "ctrl-s test")
      {editor, _buffer} = start_editor(file_path: path)

      send_key(editor, ?s, @ctrl)

      assert File.read!(path) == "ctrl-s test"
    end

    test "Ctrl+S with a fallback buffer keeps the editor alive" do
      {:ok, editor} =
        MingaEditor.start_link(
          name: :"editor_#{:erlang.unique_integer([:positive])}",
          port_manager: nil,
          buffer: nil,
          width: 40,
          height: 10,
          editing_model: :vim
        )

      send_key(editor, ?s, @ctrl)

      refute_process_down(editor)
    end
  end

  describe "tab-aware quit command state" do
    test ":q with multiple tabs closes the active tab" do
      {state, _buffer} = start_command_state("first file")
      {state, closed_tab_buffer} = add_file_tab_with_buffer(state)
      closed_tab_id = EditorState.tab_bar(state).active_id

      result = BufferManagement.execute(state, {:execute_ex_command, {:quit, []}})

      remaining_tab_ids =
        result |> EditorState.tab_bar() |> Map.fetch!(:tabs) |> Enum.map(& &1.id)

      assert tab_count(result) == 1
      refute closed_tab_id in remaining_tab_ids
      refute_process_down(closed_tab_buffer)
    end

    test ":q with a single clean file tab prompts before exiting" do
      {state, buffer} = start_command_state("first file")
      initial_tab_labels = tab_labels(state)
      initial_active_id = EditorState.tab_bar(state).active_id

      result = BufferManagement.execute(state, {:execute_ex_command, {:quit, []}})

      assert result.pending_quit == :quit
      assert result.shell_state.status_msg == "Quit Minga? (y/n)"
      assert tab_count(result) == 1
      assert result.workspace.buffers.active == buffer
      assert BufferProcess.content(result.workspace.buffers.active) == "first file"
      assert EditorState.tab_bar(result).active_id == initial_active_id
      assert tab_labels(result) == initial_tab_labels
      refute Enum.any?(tab_labels(result), &String.starts_with?(&1, "[new"))
    end

    test ":q with a single clean file tab cancels without changing state" do
      {state, buffer} = start_command_state("first file")
      initial_tab_labels = tab_labels(state)
      initial_active_id = EditorState.tab_bar(state).active_id

      prompted = BufferManagement.execute(state, {:execute_ex_command, {:quit, []}})

      assert prompted.pending_quit == :quit
      assert prompted.shell_state.status_msg == "Quit Minga? (y/n)"
      refute Enum.any?(tab_labels(prompted), &String.starts_with?(&1, "[new"))

      result = BufferManagement.execute(prompted, :confirm_quit_no)

      assert result.pending_quit == nil
      assert result.shell_state.status_msg == nil
      assert result.workspace.buffers.active == buffer
      assert BufferProcess.content(result.workspace.buffers.active) == "first file"
      assert EditorState.tab_bar(result).active_id == initial_active_id
      assert tab_labels(result) == initial_tab_labels
      refute Enum.any?(tab_labels(result), &String.starts_with?(&1, "[new"))
    end

    test ":q with the last file tab and an agent tab prompts instead of activating the agent" do
      {state, _buffer} = start_command_state("first file")
      {state, _agent_tab_id} = add_agent_tab_after_active_and_return_to_file(state)
      active_tab_id = EditorState.tab_bar(state).active_id

      result = BufferManagement.execute(state, {:execute_ex_command, {:quit, []}})

      assert result.pending_quit == :quit
      assert result.shell_state.status_msg == "Quit Minga? (y/n)"
      assert tab_count(result) == 2
      assert EditorState.tab_bar(result).active_id == active_tab_id
      assert EditorState.active_tab_kind(result) == :file
      refute Enum.any?(tab_labels(result), &String.starts_with?(&1, "[new"))
    end

    test ":q with a file and agent neighbor activates another file tab" do
      {state, _buffer} = start_command_state("first file")
      {state, closed_tab_buffer} = add_file_tab_with_buffer(state)
      closed_tab_id = EditorState.tab_bar(state).active_id
      {state, agent_tab_id} = add_agent_tab_after_active_and_return_to_file(state)

      result = BufferManagement.execute(state, {:execute_ex_command, {:quit, []}})

      assert tab_count(result) == 2
      assert EditorState.active_tab_kind(result) == :file
      refute EditorState.tab_bar(result).active_id == agent_tab_id
      refute EditorState.tab_bar(result).active_id == closed_tab_id
      refute Enum.any?(tab_labels(result), &String.starts_with?(&1, "[new"))
      refute_process_down(closed_tab_buffer)
    end
  end

  describe "close_other_tabs command state" do
    test "closes all tabs except the active tab" do
      {state, _buffer} = start_command_state("first file")

      state =
        state
        |> add_file_tab("second.txt")
        |> add_file_tab("third.txt")

      active_tab_id = EditorState.tab_bar(state).active_id

      result = BufferManagement.execute(state, :close_other_tabs)

      assert tab_count(result) == 1
      assert EditorState.tab_bar(result).active_id == active_tab_id
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

  describe "dirty quit confirmation" do
    test "quit prompts for dirty buffers and n cancels" do
      {state, buffer} = start_command_state("hello")
      BufferProcess.insert_char(buffer, "X")

      state = BufferManagement.execute(state, {:execute_ex_command, {:quit, []}})
      assert state.pending_quit == :quit
      assert state.shell_state.status_msg =~ "Modified buffers"
      refute Enum.any?(tab_labels(state), &String.starts_with?(&1, "[new"))

      result = BufferManagement.execute(state, :confirm_quit_no)
      assert result.pending_quit == nil
      assert result.shell_state.status_msg == nil
      assert tab_labels(result) == tab_labels(state)
      refute Enum.any?(tab_labels(result), &String.starts_with?(&1, "[new"))
    end

    test "Escape cancels dirty quit confirmation through the input router" do
      {editor, buffer} = start_editor(content: "hello")
      BufferProcess.insert_char(buffer, "X")

      state = send_keys(editor, ":q\r")
      assert state.pending_quit == :quit
      refute Enum.any?(tab_labels(state), &String.starts_with?(&1, "[new"))

      state = send_key(editor, 27)
      assert state.pending_quit == nil
      refute Enum.any?(tab_labels(state), &String.starts_with?(&1, "[new"))
    end
  end

  defp start_editor(opts) do
    options_server =
      Keyword.get_lazy(opts, :options_server, fn -> start_supervised!({Options, name: nil}) end)

    buffer_opts = [options_server: options_server]

    buffer_opts =
      opts
      |> Keyword.take([:content, :file_path])
      |> Keyword.merge(buffer_opts)

    {:ok, buffer} = BufferProcess.start_link(buffer_opts)

    {:ok, editor} =
      MingaEditor.start_link(
        name: :"editor_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        options_server: options_server,
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

  defp send_keys(editor, text) do
    text
    |> String.to_charlist()
    |> Enum.reduce(nil, fn char, _state -> send_key(editor, char) end)
  end

  defp send_key(editor, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    :sys.get_state(editor, @sync_timeout)
  end

  defp add_file_tab(state, label) do
    {:ok, buffer} = BufferProcess.start_link(content: "#{label} content")
    EditorState.add_buffer(state, buffer, context: :open)
  end

  defp add_file_tab_with_buffer(state) do
    {:ok, buffer} = BufferProcess.start_link(content: "second.txt content")
    {EditorState.add_buffer(state, buffer, context: :open), buffer}
  end

  defp add_agent_tab_after_active_and_return_to_file(state) do
    active_file_tab_id = EditorState.tab_bar(state).active_id
    {tb, agent_tab} = TabBar.add(EditorState.tab_bar(state), :agent, "Agent")
    tb = TabBar.switch_to(tb, active_file_tab_id)
    {EditorState.set_tab_bar(state, tb), agent_tab.id}
  end

  defp refute_process_down(pid) do
    ref = Process.monitor(pid)
    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}
    Process.demonitor(ref, [:flush])
  end

  defp tab_labels(state) do
    state
    |> EditorState.tab_bar()
    |> Map.fetch!(:tabs)
    |> Enum.map(& &1.label)
  end

  defp tab_count(state), do: state |> EditorState.tab_bar() |> TabBar.count()
end
