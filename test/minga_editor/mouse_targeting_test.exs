defmodule MingaEditor.MouseTargetingTest do
  @moduledoc "Production mouse dispatch tests for buffer targets in inactive split panes."

  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Commands.Helpers
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Layout
  alias MingaEditor.Mouse
  alias MingaEditor.Mouse.HitTest
  alias MingaEditor.Mouse.Target.Buffer, as: BufferTarget
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Startup
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.WindowFocus
  alias MingaEditor.WindowTree

  @super 0x08
  @ctrl 0x02

  setup do
    Minga.LSP.SyncServer.clear_registry()
    on_exit(&Minga.LSP.SyncServer.clear_registry/0)
    :ok
  end

  test "middle-click pastes once into a scrolled right split while the left split stays unchanged" do
    {state, left, right} = split_state(:vertical, 1)
    state = set_viewport(state, 2, %{top: 2, left: 3})
    state = Helpers.put_register_with_clipboard_override(state, "Z", :yank, :charwise, :none)
    left_cursor = BufferProcess.cursor(left)
    {row, col} = target_screen_cell(state, 2, 1, 2)

    assert {:buffer, %BufferTarget{window_id: 2, buffer: ^right} = target} =
             HitTest.resolve_buffer(state, row, col)

    assert BufferTarget.position(target) == {3, 5}

    focused = Mouse.handle(state, row, col, :middle, 0, :press, 1)

    assert focused.workspace.windows.active == 2
    assert focused.workspace.buffers.active == right
    assert BufferProcess.content(left) == left_content()
    assert BufferProcess.cursor(left) == left_cursor
    assert BufferProcess.content(right) == String.replace(right_content(), "right 3", "right Z3")
  end

  test "middle-click pastes into the left split while the right split stays unchanged" do
    {state, left, right} = split_state(:vertical, 2)
    state = Helpers.put_register_with_clipboard_override(state, "Z", :yank, :charwise, :none)
    right_cursor = BufferProcess.cursor(right)
    {row, col} = target_screen_cell(state, 1, 1, 2)

    focused = Mouse.handle(state, row, col, :middle, 0, :press, 1)

    assert focused.workspace.windows.active == 1
    assert focused.workspace.buffers.active == left
    assert BufferProcess.content(left) == String.replace(left_content(), "left 1", "lefZt 1")
    assert BufferProcess.content(right) == right_content()
    assert BufferProcess.cursor(right) == right_cursor
  end

  test "Cmd-click requests a definition once from the bottom split while the top split stays unchanged" do
    {state, top, bottom} = split_state(:horizontal, 1)
    {state, top_path, bottom_path} = attach_file_paths(state, top, bottom)
    client = start_fake_lsp_client()
    register_lsp_client(bottom, client)
    top_cursor = BufferProcess.cursor(top)
    {row, col} = target_screen_cell(state, 2, 2, 4)

    focused = Mouse.handle(state, row, col, :left, @super, :press, 1)

    assert focused.workspace.windows.active == 2
    assert focused.workspace.buffers.active == bottom
    assert BufferProcess.cursor(top) == top_cursor
    assert BufferProcess.content(top) == left_content()
    assert BufferProcess.content(bottom) == right_content()

    bottom_uri = Minga.LSP.SyncServer.path_to_uri(bottom_path)
    top_uri = Minga.LSP.SyncServer.path_to_uri(top_path)

    assert_receive {:lsp_request, "textDocument/definition",
                    %{
                      "textDocument" => %{"uri" => ^bottom_uri},
                      "position" => %{"line" => 2, "character" => 4}
                    }}

    refute_receive {:lsp_request, "textDocument/definition",
                    %{"textDocument" => %{"uri" => ^top_uri}}},
                   50

    refute_receive {:lsp_request, "textDocument/definition", _params}, 50
  end

  test "Ctrl-click in the TUI requests a definition from the top split while the bottom split stays unchanged" do
    {state, top, bottom} = split_state(:horizontal, 2)
    {state, top_path, bottom_path} = attach_file_paths(state, top, bottom)
    client = start_fake_lsp_client()
    register_lsp_client(top, client)
    bottom_cursor = BufferProcess.cursor(bottom)
    {row, col} = target_screen_cell(state, 1, 2, 3)

    focused = Mouse.handle(state, row, col, :left, @ctrl, :press, 1)

    assert focused.workspace.windows.active == 1
    assert focused.workspace.buffers.active == top
    assert BufferProcess.cursor(bottom) == bottom_cursor
    assert BufferProcess.content(top) == left_content()
    assert BufferProcess.content(bottom) == right_content()

    top_uri = Minga.LSP.SyncServer.path_to_uri(top_path)
    bottom_uri = Minga.LSP.SyncServer.path_to_uri(bottom_path)

    assert_receive {:lsp_request, "textDocument/definition",
                    %{
                      "textDocument" => %{"uri" => ^top_uri},
                      "position" => %{"line" => 2, "character" => 3}
                    }}

    refute_receive {:lsp_request, "textDocument/definition",
                    %{"textDocument" => %{"uri" => ^bottom_uri}}},
                   50

    refute_receive {:lsp_request, "textDocument/definition", _params}, 50
  end

  test "a miss does not focus, paste, or move either split cursor" do
    {state, left, right} = split_state(:vertical, 1)
    state = Helpers.put_register_with_clipboard_override(state, "Z", :yank, :charwise, :none)
    left_cursor = BufferProcess.cursor(left)
    right_cursor = BufferProcess.cursor(right)

    unchanged = Mouse.handle(state, 9_999, 9_999, :middle, 0, :press, 1)

    assert unchanged.workspace.windows.active == 1
    assert unchanged.workspace.buffers.active == left
    assert BufferProcess.content(left) == left_content()
    assert BufferProcess.content(right) == right_content()
    assert BufferProcess.cursor(left) == left_cursor
    assert BufferProcess.cursor(right) == right_cursor
  end

  test "middle-click returns the exact original state when the resolved target dies after focus" do
    {state, left, right} = split_state(:vertical, 1)
    target = start_failing_buffer_proxy(right, 2)
    state = replace_window_buffer(state, 2, right, target)
    state = Helpers.put_register_with_clipboard_override(state, "Z", :yank, :charwise, :none)
    {row, col} = target_screen_cell(state, 2, 1, 2)
    monitor = Process.monitor(target)

    unchanged = Mouse.handle(state, row, col, :middle, 0, :press, 1)

    assert unchanged == state
    assert_receive {:DOWN, ^monitor, :process, ^target, :target_unavailable}
    assert BufferProcess.content(left) == left_content()
    assert BufferProcess.content(right) == right_content()
  end

  test "definition click returns the pre-gesture state when the resolved target dies after focus" do
    {state, left, right} = split_state(:vertical, 1)
    {state, _left_path, _right_path} = attach_file_paths(state, left, right)
    client = start_fake_lsp_client()
    register_lsp_client(left, client)
    target = start_failing_buffer_proxy(right, 2)
    state = replace_window_buffer(state, 2, right, target)
    {row, col} = target_screen_cell(state, 2, 1, 2)
    monitor = Process.monitor(target)

    unchanged = Mouse.handle(state, row, col, :left, @super, :press, 1)

    assert unchanged == state
    assert_receive {:DOWN, ^monitor, :process, ^target, :target_unavailable}
    assert BufferProcess.content(left) == left_content()
    assert BufferProcess.content(right) == right_content()
    refute_receive {:lsp_request, "textDocument/definition", _params}, 50
  end

  defp split_state(direction, active_id) do
    {state, first} = start_mouse_state(left_content())
    second = start_test_buffer(state, right_content())
    :ok = BufferProcess.move_to(first, {0, 1})
    :ok = BufferProcess.move_to(second, {4, 2})

    buffers = Buffers.add_background(state.workspace.buffers, second)
    {:ok, tree} = WindowTree.split(state.workspace.windows.tree, 1, direction, 2)

    windows =
      state.workspace.windows
      |> Windows.add_window(Window.new(2, second, 20, 80, {4, 2}))
      |> Windows.set_tree(tree)

    workspace =
      state.workspace
      |> SessionState.set_buffers(buffers)
      |> SessionState.set_windows(windows)

    state = %{state | workspace: workspace}

    case active_id do
      1 -> state
      2 -> WindowFocus.focus(state, 2)
    end
    |> then(&{&1, first, second})
  end

  defp set_viewport(state, window_id, offsets) do
    window = Map.fetch!(state.workspace.windows.map, window_id)
    %Viewport{} = viewport = window.viewport
    viewport = %Viewport{viewport | top: offsets.top, left: offsets.left}
    windows = Windows.set_viewport(state.workspace.windows, window_id, viewport)
    %{state | workspace: SessionState.set_windows(state.workspace, windows)}
  end

  defp replace_window_buffer(state, window_id, old_buffer, target_buffer) do
    list =
      Enum.map(state.workspace.buffers.list, &if(&1 == old_buffer, do: target_buffer, else: &1))

    buffers =
      Buffers.replace_list(
        state.workspace.buffers,
        list,
        state.workspace.buffers.active_index
      )

    window = Map.fetch!(state.workspace.windows.map, window_id)

    windows =
      Windows.replace_window(
        state.workspace.windows,
        window_id,
        Window.show_buffer(window, target_buffer)
      )

    workspace =
      state.workspace
      |> SessionState.set_buffers(buffers)
      |> SessionState.set_windows(windows)

    %{state | workspace: workspace}
  end

  defp target_screen_cell(state, window_id, local_row, visible_col) do
    %{content: {content_row, content_col, _width, _height}} =
      Map.fetch!(Layout.get(state).window_layouts, window_id)

    {:buffer, buffer} = Map.fetch!(state.workspace.windows.map, window_id).content
    gutter = HitTest.buffer_gutter_width(buffer, BufferProcess.line_count(buffer))
    {content_row + local_row, content_col + gutter + visible_col}
  end

  defp attach_file_paths(state, first, second) do
    root = state.workspace.file_tree.project_root
    first_path = Path.join(root, "first.ex")
    second_path = Path.join(root, "second.ex")
    :ok = BufferProcess.save_as(first, first_path)
    :ok = BufferProcess.save_as(second, second_path)
    {state, first_path, second_path}
  end

  defp register_lsp_client(buffer, client) do
    Minga.LSP.SyncServer.put_clients(buffer, [client])
    :ok
  end

  defp start_fake_lsp_client do
    parent = self()

    start_supervised!(
      {Task, fn -> fake_lsp_client_loop(parent) end},
      id: {:fake_lsp_client, make_ref()}
    )
  end

  defp fake_lsp_client_loop(parent) do
    receive do
      {:"$gen_cast", {:async_request, method, params, _caller, _ref}} ->
        send(parent, {:lsp_request, method, params})
        fake_lsp_client_loop(parent)

      _other ->
        fake_lsp_client_loop(parent)
    end
  end

  defp start_failing_buffer_proxy(delegate, fail_on_move) do
    start_supervised!(
      {Task, fn -> failing_buffer_proxy_loop(delegate, fail_on_move, 0) end},
      id: {:failing_buffer_proxy, make_ref()}
    )
  end

  defp failing_buffer_proxy_loop(delegate, fail_on_move, move_count) do
    receive do
      {:"$gen_call", _from, {:move_to, _position}} when move_count + 1 == fail_on_move ->
        exit(:target_unavailable)

      {:"$gen_call", from, {:move_to, _position} = request} ->
        GenServer.reply(from, GenServer.call(delegate, request))
        failing_buffer_proxy_loop(delegate, fail_on_move, move_count + 1)

      {:"$gen_call", from, request} ->
        GenServer.reply(from, GenServer.call(delegate, request))
        failing_buffer_proxy_loop(delegate, fail_on_move, move_count)

      {:"$gen_cast", request} ->
        GenServer.cast(delegate, request)
        failing_buffer_proxy_loop(delegate, fail_on_move, move_count)
    end
  end

  defp start_mouse_state(content) do
    id = System.unique_integer([:positive])
    events_registry = Module.concat(__MODULE__, "Events#{id}")
    sidebar_registry = Module.concat(__MODULE__, "Sidebar#{id}")
    project_root = Path.join(System.tmp_dir!(), "minga-mouse-targeting-#{id}")
    File.mkdir_p!(project_root)
    on_exit(fn -> File.rm_rf!(project_root) end)

    start_supervised!({Minga.Events, name: events_registry}, id: {:events, id})
    start_supervised!({Sidebar, name: sidebar_registry, notify: false}, id: {:sidebars, id})

    options_server =
      start_supervised!({Minga.Config.Options, name: nil, events_registry: events_registry},
        id: {:options, id}
      )

    buffer =
      start_supervised!(
        {BufferProcess,
         content: content, events_registry: events_registry, options_server: options_server},
        id: {:buffer, id}
      )

    assert {:ok, :none} = BufferProcess.set_option(buffer, :clipboard, :none)

    state =
      Startup.build_initial_state(
        port_manager: nil,
        buffer: buffer,
        width: 80,
        height: 20,
        editing_model: :vim,
        options_server: options_server,
        events_registry: events_registry,
        sidebar_registry: sidebar_registry,
        project_root: project_root,
        suppress_tool_prompts: true
      )

    {state, buffer}
  end

  defp start_test_buffer(state, content) do
    buffer =
      start_supervised!(
        {BufferProcess,
         content: content,
         events_registry: state.extension_surfaces.events_registry,
         options_server: state.interaction.options_server},
        id: {:secondary_buffer, make_ref()}
      )

    assert {:ok, :none} = BufferProcess.set_option(buffer, :clipboard, :none)
    buffer
  end

  defp left_content, do: Enum.map_join(0..5, "\n", &"left #{&1}")
  defp right_content, do: Enum.map_join(0..5, "\n", &"right #{&1}")
end
