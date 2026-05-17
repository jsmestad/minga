defmodule MingaEditor.StatusBar.DataTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options
  alias Minga.Mode.VisualState
  alias MingaAgent.Subagent.Handle
  alias MingaEditor.StatusBar.Data
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias MingaEditor.Workspace.State, as: WorkspaceState

  test "projects running background subagent count and active label" do
    handle1 = handle("session-2", "tests")
    handle2 = handle("session-3", "docs")

    tb = TabBar.new(Tab.new_file(1, "main.ex"))
    {tb, tab1} = TabBar.add(tb, :agent, "subagent tests")

    tb =
      TabBar.update_tab(tb, tab1.id, fn tab ->
        tab
        |> Tab.set_session(handle1.pid)
        |> Tab.set_agent_status(:thinking)
        |> Tab.mark_background_subagent(handle1)
      end)

    {tb, tab2} = TabBar.add(tb, :agent, "subagent docs")

    tb =
      TabBar.update_tab(tb, tab2.id, fn tab ->
        tab
        |> Tab.set_session(handle2.pid)
        |> Tab.set_agent_status(:idle)
        |> Tab.mark_background_subagent(handle2)
      end)

    state = state_with_tab_bar(TabBar.switch_to(tb, tab1.id))
    data = Data.from_state(state) |> Data.to_modeline_data()

    assert data.background_subagent_count == 1
    assert data.active_background_subagent_label == "session-2: tests"
  end

  test "uses options server values when no active buffer is available" do
    options = start_supervised!({Options, name: nil})
    {:ok, _} = Options.set_for_filetype(options, :text, :indent_with, :tabs)
    {:ok, _} = Options.set_for_filetype(options, :text, :tab_width, 4)

    state = %EditorState{
      port_manager: self(),
      options_server: options,
      workspace: %WorkspaceState{viewport: Viewport.new(24, 80)},
      shell_state: %MingaEditor.Shell.Traditional.State{}
    }

    {:buffer, data} = Data.from_state(state)

    assert data.indent_type == :tabs
    assert data.indent_size == 4
  end

  test "buffer-local indent options override filetype defaults" do
    options = start_supervised!({Options, name: nil})
    {:ok, _} = Options.set_for_filetype(options, :elixir, :indent_with, :spaces)
    {:ok, _} = Options.set_for_filetype(options, :elixir, :tab_width, 2)

    {state, buf} = state_with_buffer("hello", options, :elixir)
    BufferProcess.set_option(buf, :indent_with, :tabs)
    BufferProcess.set_option(buf, :tab_width, 4)

    {:buffer, data} = Data.from_state(state)

    assert data.indent_type == :tabs
    assert data.indent_size == 4
  end

  test "visual char selection reports grapheme count" do
    {state, _buf} = state_with_buffer("héllo", nil, :text)

    state =
      EditorState.transition_mode(state, :visual, %VisualState{
        visual_type: :char,
        visual_anchor: {0, 0}
      })

    {:buffer, data} = Data.from_state(state)

    assert data.selection_info == {:chars, 5}
  end

  test "visual line selection reports selected line count" do
    {state, _buf} = state_with_buffer("one\ntwo\nthree", nil, :text)

    state =
      EditorState.transition_mode(state, :visual, %VisualState{
        visual_type: :line,
        visual_anchor: {0, 0}
      })

    {:buffer, data} = Data.from_state(state)

    assert data.selection_info == {:lines, 3}
  end

  defp state_with_tab_bar(tab_bar) do
    %EditorState{
      port_manager: self(),
      workspace: %WorkspaceState{viewport: Viewport.new(24, 80)},
      shell_state: %MingaEditor.Shell.Traditional.State{tab_bar: tab_bar}
    }
  end

  defp state_with_buffer(content, options_server, filetype) do
    options_server = options_server || start_supervised!({Options, name: nil})
    buf = start_buffer(content, filetype)
    workspace = workspace_with_buffer(buf)

    state =
      %EditorState{
        port_manager: self(),
        options_server: options_server,
        workspace: workspace,
        shell_state: %MingaEditor.Shell.Traditional.State{}
      }

    {state, buf}
  end

  defp workspace_with_buffer(buf) do
    %WorkspaceState{
      viewport: Viewport.new(24, 80),
      buffers: %Buffers{list: [buf], active_index: 0, active: buf},
      windows: %Windows{
        tree: WindowTree.new(1),
        map: %{1 => Window.new(1, buf, 24, 80)},
        active: 1,
        next_id: 2
      }
    }
  end

  defp start_buffer(content, filetype) do
    buf = start_supervised!({BufferProcess, [content: "", filetype: filetype]})
    :ok = BufferProcess.insert_text(buf, content)
    buf
  end

  defp handle(session_id, task) do
    Handle.new(session_id: session_id, pid: self(), task: task, started_at: DateTime.utc_now())
  end
end
