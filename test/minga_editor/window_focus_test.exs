defmodule MingaEditor.WindowFocusTest do
  use ExUnit.Case, async: true

  alias Minga.Parser.Manager
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.BottomPanel
  alias MingaEditor.HighlightSync
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Entry
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Windows
  alias MingaEditor.Window
  alias MingaEditor.WindowFocus
  alias MingaEditor.WindowTree

  import MingaEditor.RenderPipeline.TestHelpers

  test "focus saves the outgoing cursor, restores the target, updates session state, and blurs the panel" do
    {state, first_buffer, second_buffer} = split_state()
    :ok = BufferProcess.move_to(first_buffer, {2, 0})

    panel = %BottomPanel{} |> BottomPanel.show() |> BottomPanel.focus()

    state =
      then(state, fn root ->
        shell_state =
          MingaEditor.Shell.Traditional.State.install_bottom_panel(
            MingaEditor.Shell.Runtime.state(root.shell_runtime),
            panel
          )

        %{
          root
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
        }
      end)

    focused = WindowFocus.focus(state, 2)

    assert focused.workspace.windows.active == 2
    assert focused.workspace.buffers.active == second_buffer
    assert focused.workspace.buffers.active_index == 1
    assert Map.fetch!(focused.workspace.windows.map, 1).cursor == {2, 0}
    assert BufferProcess.cursor(second_buffer) == {0, 1}
    refute BottomPanel.focused?(focused.shell_runtime.state.bottom_panel)
  end

  test "focus restores parser presentation for an evicted inactive split buffer", %{test: test} do
    manager =
      start_supervised!(
        {Manager,
         name: Module.concat(__MODULE__, "Parser#{test}"), parser_path: "/missing/minga-parser"}
      )

    {state, _first_buffer, second_buffer} = split_state(parser_manager: manager)
    state = HighlightSync.setup_for_buffer_pid(state, second_buffer)

    assert is_integer(Manager.buffer_id(second_buffer, manager))

    Process.sleep(2)

    evicted = HighlightSync.evict_inactive(state, ttl_ms: 0)

    assert Manager.buffer_id(second_buffer, manager) == nil
    refute Map.has_key?(evicted.parser.highlighting.highlights, second_buffer)

    focused = WindowFocus.focus(evicted, 2)

    assert focused.workspace.buffers.active == second_buffer
    assert is_integer(Manager.buffer_id(second_buffer, manager))
    assert Map.has_key?(focused.parser.highlighting.highlights, second_buffer)
  end

  test "focus presents real active overrides outside the buffer list and excludes fake pids", %{
    test: test
  } do
    manager =
      start_supervised!(
        {Manager,
         name: Module.concat(__MODULE__, "Parser#{test}"), parser_path: "/missing/minga-parser"}
      )

    state = base_state(content: "first", filetype: :elixir, parser_manager: manager)
    first_buffer = state.workspace.buffers.active
    unlisted_buffer = start_supervised!({BufferProcess, content: "override", filetype: :elixir})

    focused =
      WindowFocus.focus(state_with_unlisted_window(state, first_buffer, unlisted_buffer), 2)

    assert focused.workspace.buffers.active == unlisted_buffer
    assert focused.workspace.buffers.list == [first_buffer]
    assert is_integer(Manager.buffer_id(unlisted_buffer, manager))
    assert Map.has_key?(focused.parser.highlighting.highlights, unlisted_buffer)

    fake_buffer = start_fake_buffer()
    focused = WindowFocus.focus(state_with_unlisted_window(state, first_buffer, fake_buffer), 2)

    assert focused.workspace.buffers.active == fake_buffer
    assert focused.workspace.buffers.list == [first_buffer]
    assert Manager.buffer_id(fake_buffer, manager) == nil
    refute Map.has_key?(focused.parser.highlighting.highlights, fake_buffer)
    refute_received {:fake_buffer_call, :filetype}
  end

  test "focusing a surviving split commits the same session and presentation invariant" do
    {state, _first_buffer, second_buffer} = split_state()
    {:ok, remaining_windows} = Windows.remove_window(state.workspace.windows, 1)
    panel = %BottomPanel{} |> BottomPanel.show() |> BottomPanel.focus()

    state =
      state
      |> then(fn root ->
        shell_state =
          MingaEditor.Shell.Traditional.State.install_bottom_panel(
            MingaEditor.Shell.Runtime.state(root.shell_runtime),
            panel
          )

        %{
          root
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
        }
      end)
      |> then(fn state ->
        %{
          state
          | workspace:
              then(
                state.workspace,
                &MingaEditor.Session.State.set_cmd_hover_link(&1, {{0, 0}, {0, 3}})
              )
        }
      end)
      |> then(fn state ->
        %{
          state
          | workspace:
              then(state.workspace, fn workspace ->
                MingaEditor.Session.State.set_cmd_hover_cell(workspace, {4, 7})
              end)
        }
      end)

    focused = WindowFocus.focus_surviving_window(state, remaining_windows, 2)

    assert focused.workspace.windows.active == 2
    assert focused.workspace.buffers.active == second_buffer
    assert focused.workspace.buffers.active_index == 1
    assert focused.workspace.hover_observation.link == nil
    assert focused.workspace.hover_observation.cell == nil
    assert BufferProcess.cursor(second_buffer) == {0, 1}
    refute BottomPanel.focused?(focused.shell_runtime.state.bottom_panel)
  end

  test "focus_surviving_window restores parser presentation for an evicted surviving buffer", %{
    test: test
  } do
    manager =
      start_supervised!(
        {Manager,
         name: Module.concat(__MODULE__, "Parser#{test}"), parser_path: "/missing/minga-parser"}
      )

    {state, _first_buffer, second_buffer} = split_state(parser_manager: manager)
    {:ok, remaining_windows} = Windows.remove_window(state.workspace.windows, 1)
    state = HighlightSync.setup_for_buffer_pid(state, second_buffer)

    assert is_integer(Manager.buffer_id(second_buffer, manager))

    Process.sleep(2)

    evicted = HighlightSync.evict_inactive(state, ttl_ms: 0)

    assert Manager.buffer_id(second_buffer, manager) == nil
    refute Map.has_key?(evicted.parser.highlighting.highlights, second_buffer)

    focused = WindowFocus.focus_surviving_window(evicted, remaining_windows, 2)

    assert focused.workspace.buffers.active == second_buffer
    assert is_integer(Manager.buffer_id(second_buffer, manager))
    assert Map.has_key?(focused.parser.highlighting.highlights, second_buffer)
  end

  test "active-shell blur dispatches through an alternate shell contract" do
    state = base_state()

    entry =
      Entry.builtin!(
        :fake,
        MingaEditor.Test.FakeShell,
        "Fake",
        "Focus contract test shell",
        false
      )

    state = %{state | shell_runtime: Runtime.new(entry, %{events: []})}
    focused = WindowFocus.focus(state, state.workspace.windows.active)

    assert Runtime.state(focused.shell_runtime).events == [:bottom_panel_blurred]
    assert focused.workspace == state.workspace
  end

  test "focusing the active window only blurs Traditional bottom-panel presentation" do
    state = base_state()
    panel = %BottomPanel{} |> BottomPanel.show() |> BottomPanel.focus()

    state =
      then(state, fn root ->
        shell_state =
          MingaEditor.Shell.Traditional.State.install_bottom_panel(
            MingaEditor.Shell.Runtime.state(root.shell_runtime),
            panel
          )

        %{
          root
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
        }
      end)

    focused = WindowFocus.focus(state, state.workspace.windows.active)

    assert focused.workspace == state.workspace
    refute BottomPanel.focused?(focused.shell_runtime.state.bottom_panel)
  end

  test "missing windows and dead buffer processes leave focus state unchanged" do
    {state, _first_buffer, second_buffer} = split_state()
    assert WindowFocus.focus(state, 99) == state

    monitor = Process.monitor(second_buffer)
    GenServer.stop(second_buffer, :normal)
    assert_receive {:DOWN, ^monitor, :process, ^second_buffer, :normal}

    assert WindowFocus.focus(state, 2) == state

    {state, first_buffer, _second_buffer} = split_state()
    monitor = Process.monitor(first_buffer)
    GenServer.stop(first_buffer, :normal)
    assert_receive {:DOWN, ^monitor, :process, ^first_buffer, :normal}

    assert WindowFocus.focus(state, 2) == state
  end

  test "cursor-source mismatch returns a focused failure and leaves state unchanged" do
    {state, _first_buffer, second_buffer} = split_state()

    mismatched = %{
      state
      | workspace:
          SessionState.set_buffers(state.workspace, Buffers.switch_to(state.workspace.buffers, 1))
    }

    assert WindowFocus.focus_result(mismatched, 2) ==
             {:error, :cursor_source_mismatch}

    assert WindowFocus.focus(mismatched, 2) == mismatched

    assert WindowFocus.remember_active_cursor_result(mismatched) ==
             {:error, :cursor_source_mismatch}

    assert BufferProcess.cursor(second_buffer) == {0, 1}
  end

  test "active cursor snapshots require a matching live buffer window" do
    {state, first_buffer, _second_buffer} = split_state()
    :ok = BufferProcess.move_to(first_buffer, {1, 2})

    remembered = WindowFocus.remember_active_cursor(state)
    assert Map.fetch!(remembered.workspace.windows.map, 1).cursor == {1, 2}

    mismatched =
      then(state, fn state ->
        %{
          state
          | workspace:
              SessionState.set_buffers(
                state.workspace,
                Buffers.switch_to(state.workspace.buffers, 1)
              )
        }
      end)

    assert WindowFocus.remember_active_cursor(mismatched) == mismatched
  end

  test "active cursor snapshot leaves state unchanged when the matching buffer has died" do
    {state, first_buffer, _second_buffer} = split_state()
    monitor = Process.monitor(first_buffer)
    GenServer.stop(first_buffer, :normal)
    assert_receive {:DOWN, ^monitor, :process, ^first_buffer, :normal}

    assert WindowFocus.remember_active_cursor(state) == state
  end

  defp split_state(opts \\ []) do
    state = base_state(Keyword.merge([content: "first\nline\nend"], opts))
    first_buffer = state.workspace.buffers.active
    second_buffer = start_supervised!({BufferProcess, content: "second line", filetype: :elixir})
    :ok = BufferProcess.move_to(second_buffer, {0, 1})

    buffers = state.workspace.buffers |> Buffers.add(second_buffer) |> Buffers.switch_to(0)

    {:ok, tree} = WindowTree.split(state.workspace.windows.tree, 1, :vertical, 2)

    windows =
      state.workspace.windows
      |> Windows.add_window(Window.new(2, second_buffer, 24, 80, {0, 1}))
      |> Windows.set_tree(tree)

    workspace =
      state.workspace
      |> SessionState.activate_buffer(buffers)
      |> SessionState.set_windows(windows)

    {then(state, fn state -> %{state | workspace: workspace} end), first_buffer, second_buffer}
  end

  defp state_with_unlisted_window(state, listed_buffer, unlisted_buffer) do
    buffers = %{
      state.workspace.buffers
      | active: listed_buffer,
        list: [listed_buffer],
        active_index: 0
    }

    {:ok, tree} = WindowTree.split(state.workspace.windows.tree, 1, :vertical, 2)

    windows =
      state.workspace.windows
      |> Windows.add_window(Window.new(2, unlisted_buffer, 24, 80, {0, 0}))
      |> Windows.set_tree(tree)

    workspace =
      state.workspace
      |> SessionState.activate_buffer(buffers)
      |> SessionState.set_windows(windows)

    %{state | workspace: workspace}
  end

  defp start_fake_buffer do
    parent = self()

    pid =
      spawn_link(fn ->
        fake_buffer_loop(parent, {0, 0})
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp fake_buffer_loop(parent, cursor) do
    receive do
      {:"$gen_call", from, {:move_to, new_cursor}} ->
        GenServer.reply(from, :ok)
        fake_buffer_loop(parent, new_cursor)

      {:"$gen_call", from, :cursor} ->
        GenServer.reply(from, cursor)
        fake_buffer_loop(parent, cursor)

      {:"$gen_call", from, :filetype} ->
        send(parent, {:fake_buffer_call, :filetype})
        GenServer.reply(from, :elixir)
        fake_buffer_loop(parent, cursor)
    end
  end
end
