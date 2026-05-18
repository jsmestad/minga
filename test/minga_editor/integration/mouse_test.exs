defmodule Minga.Integration.MouseTest do
  @moduledoc """
  Thin integration smoke tests for mouse events crossing the live Editor GenServer boundary.

  Gesture details live in `MingaEditor.MouseTest` and `MingaEditor.MouseMultiClickTest`. This file keeps only the cases that need the full input router, shell state, renderer, or GUI action path.
  """
  use Minga.Test.EditorCase, async: true

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree
  alias Minga.Test.HeadlessPort
  alias Minga.Test.StubServer

  @sync_timeout 15_000

  defp start_editor_with_project(content) do
    id = :erlang.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "minga-integration-mouse-#{id}")
    File.mkdir_p!(root)
    start_editor(content, project_root: root)
  end

  defp send_gui_action(%{editor: editor, port: port}, action) do
    _ = GenServer.call(editor, :api_mode, @sync_timeout)
    ref = HeadlessPort.prepare_await(port)
    send(editor, {:minga_input, {:gui_action, action}})
    {:ok, snapshot} = HeadlessPort.collect_frame(ref)
    Process.put({:last_frame_snapshot, port}, snapshot)
    :ok
  end

  defp inject_fake_session(%{editor: editor} = ctx) do
    {:ok, fake} = StubServer.start_link()

    :sys.replace_state(editor, fn state ->
      tb = state.shell_state.tab_bar

      target_tab =
        MingaEditor.State.TabBar.find_by_kind(tb, :agent) ||
          MingaEditor.State.TabBar.active(tb)

      case target_tab do
        nil -> state
        tab -> MingaEditor.State.set_tab_session(state, tab.id, fake)
      end
    end)

    ctx
  end

  defp open_agent_tab(ctx) do
    ctx = inject_fake_session(ctx)
    send_keys_sync(ctx, "<Space>aa")

    state = editor_state(ctx)

    assert state.workspace.keymap_scope == :agent,
           "expected :agent scope after SPC a a, got #{state.workspace.keymap_scope}"

    ctx
  end

  defp file_tree_separator_col(ctx) do
    wait_until_screen(
      ctx,
      fn ->
        screen_row(ctx, 1)
        |> String.graphemes()
        |> Enum.any?(&(&1 == "│"))
      end,
      message: "expected file tree separator"
    )

    screen_row(ctx, 1)
    |> String.graphemes()
    |> Enum.find_index(&(&1 == "│"))
  end

  describe "live editor mouse routing" do
    test "left click moves the buffer cursor through the input router" do
      ctx = start_editor("hello world\nsecond line\nthird line")

      send_mouse(ctx, 2, 6, :left)

      assert {1, _col} = buffer_cursor(ctx)
      assert screen_contains?(ctx, "second line")
    end

    test "file tree and editor clicks route to the matching focus scope" do
      ctx = start_editor_with_project("hello world")

      send_keys_sync(ctx, "<Space>op")
      tree_sep = file_tree_separator_col(ctx)

      send_mouse(ctx, 5, div(ctx.width, 2), :left)
      state = editor_state(ctx)

      assert state.workspace.keymap_scope == :editor,
             "clicking editor content should set :editor scope, got #{state.workspace.keymap_scope}"

      send_mouse(ctx, 5, max(tree_sep - 2, 0), :left)
      state = editor_state(ctx)

      assert FileTree.focused?(state.workspace.file_tree), "clicking file tree should focus it"

      assert state.workspace.keymap_scope == :file_tree,
             "clicking file tree should set :file_tree scope, got #{state.workspace.keymap_scope}"
    end
  end

  describe "agent tab mouse routing" do
    test "clicks focus the agent input and wheel events reach the agent chat" do
      ctx =
        "hello world"
        |> start_editor()
        |> open_agent_tab()

      input_row = ctx.height - 3
      send_mouse(ctx, input_row, 10, :left)

      state = editor_state(ctx)
      assert state.workspace.agent_ui.panel.input_focused

      send_mouse(ctx, 3, 10, :left)
      state = editor_state(ctx)
      refute state.workspace.agent_ui.panel.input_focused

      send_mouse(ctx, 5, 10, :wheel_down)

      state = editor_state(ctx)
      assert {_win_id, window} = EditorState.find_agent_chat_window(state)
      refute window.pinned, "agent chat window should be unpinned after scrolling"
    end
  end

  describe "shared post-action housekeeping" do
    test "mouse clicks exit visual mode and clear LSP selection ranges" do
      ctx = start_editor("hello world\nsecond line\nthird line")

      send_keys_sync(ctx, "v")
      assert editor_mode(ctx) == :visual

      :sys.replace_state(ctx.editor, fn state ->
        %{
          state
          | lsp:
              MingaEditor.State.LSP.set_selection_ranges(state.lsp, [%{"range" => %{}}])
              |> Map.put(:selection_range_index, 1)
        }
      end)

      assert editor_state(ctx).lsp.selection_ranges != nil

      send_mouse(ctx, 2, 5, :left)

      assert editor_mode(ctx) == :normal

      state = editor_state(ctx)
      assert state.lsp.selection_ranges == nil
      assert state.lsp.selection_range_index == 0
    end

    test "GUI tab actions run the full housekeeping pipeline" do
      ctx = start_editor("hello world\nsecond line\nthird line")
      tab_id = editor_state(ctx).shell_state.tab_bar.active_id

      send_gui_action(ctx, {:select_tab, tab_id})

      assert editor_mode(ctx) == :normal
      assert active_content(ctx) == "hello world\nsecond line\nthird line"
    end
  end
end
