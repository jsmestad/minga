defmodule MingaEditor.StatusBar.DataTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Git.Buffer, as: GitBuffer
  alias Minga.Git.Stub, as: GitStub
  alias Minga.Config.ModelineSegments
  alias Minga.Config.Options
  alias Minga.Mode.VisualState
  alias MingaAgent.SessionMetadata
  alias MingaAgent.Subagent.Handle
  alias MingaEditor.StatusBar.Data
  alias MingaEditor.Shell.Registry
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.OperationFeedback
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.State.Workspace, as: WorkspaceModel
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias MingaEditor.Session.State, as: SessionState

  defmodule MetadataSession do
    use GenServer

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl GenServer
    def init(opts), do: {:ok, Map.new(opts)}

    @impl GenServer
    def handle_call(:metadata, _from, state) do
      now = DateTime.utc_now()

      metadata = %SessionMetadata{
        id: "test-session",
        model_name: "openai_codex:gpt-5-codex",
        created_at: now,
        last_message_at: now,
        message_count: Map.fetch!(state, :message_count),
        turn_count: Map.fetch!(state, :turn_count)
      }

      {:reply, metadata, state}
    end
  end

  test "from_state carries the selected global operation separately from plain messages" do
    state = state_with_tab_bar(TabBar.new(Tab.new_file(1, "main.ex")))

    {state, operation} =
      OperationFeedback.start_in(state, :lsp_references, "main.ex", "Finding references...")

    assert {:buffer, data} = Data.from_state(state)
    assert data.selected_operation == operation
    assert data.status_msg == nil
  end

  test "from_state leaves GUI modeline segments detached by default" do
    state = state_with_tab_bar(TabBar.new(Tab.new_file(1, "main.ex")))
    data = Data.from_state(state)

    assert {:buffer, buffer_data} = data
    refute Map.has_key?(buffer_data, :modeline_segments)
  end

  describe "pending_keys (showcmd)" do
    test "is empty in a fresh normal-mode state" do
      state = state_with_tab_bar(TabBar.new(Tab.new_file(1, "main.ex")))
      {:buffer, data} = Data.from_state(state)
      assert data.pending_keys == ""
    end

    test "echoes an accumulated count from FSM state" do
      state =
        state_with_tab_bar(TabBar.new(Tab.new_file(1, "main.ex")))
        |> EditorState.update_mode_state(&%{&1 | count: 2})

      {:buffer, data} = Data.from_state(state)
      assert data.pending_keys == "2"
    end

    test "prefixes the active register selection" do
      state =
        state_with_tab_bar(TabBar.new(Tab.new_file(1, "main.ex")))
        |> MingaEditor.Editing.set_active_register("a")

      {:buffer, data} = Data.from_state(state)
      assert data.pending_keys == "\"a"
    end

    test "echoes a pending operator in operator-pending mode" do
      op_state = %Minga.Mode.OperatorPendingState{operator: :delete}

      state =
        state_with_tab_bar(TabBar.new(Tab.new_file(1, "main.ex")))
        |> EditorState.transition_mode(:operator_pending, op_state)

      {:buffer, data} = Data.from_state(state)
      assert data.pending_keys == "d"
    end

    test "composes the register prefix with operator-pending FSM state" do
      op_state = %Minga.Mode.OperatorPendingState{operator: :delete, op_count: 2}

      state =
        state_with_tab_bar(TabBar.new(Tab.new_file(1, "main.ex")))
        |> MingaEditor.Editing.set_active_register("a")
        |> EditorState.transition_mode(:operator_pending, op_state)

      {:buffer, data} = Data.from_state(state)
      assert data.pending_keys == "\"a2d"
    end

    test "clears when the which-key popup is showing" do
      state =
        state_with_tab_bar(TabBar.new(Tab.new_file(1, "main.ex")))
        |> EditorState.update_mode_state(&%{&1 | count: 2})
        |> EditorState.set_whichkey(%MingaEditor.State.WhichKey{show: true})

      {:buffer, data} = Data.from_state(state)
      assert data.pending_keys == ""
    end
  end

  test "with_modeline_segments preserves agent status command output" do
    state = state_with_tab_bar(TabBar.new(Tab.new_file(1, "main.ex")))
    state = AgentAccess.update_agent(state, &AgentState.set_status(&1, :thinking))
    {:buffer, data} = Data.from_state(state)
    data = Map.put(data, :agent_status_command, "sonnet | thinking")

    assert {:buffer, buffer_data} = Data.with_modeline_segments({:buffer, data}, state.theme)
    text = modeline_text(buffer_data.modeline_segments)

    assert String.contains?(text, "sonnet | thinking")
    refute String.contains?(text, "Thinking")
  end

  test "with_modeline_segments attaches GUI modeline segments from supplied registry" do
    table = :"status_bar_data_modeline_segments_#{System.unique_integer([:positive])}"
    start_supervised!({ModelineSegments, name: table})

    assert :ok =
             ModelineSegments.register(
               table,
               :status_bar_data_modeline_test,
               [side: :left],
               fn ctx -> {" GUI_ONLY ", ctx.info_fg, ctx.bar_bg, [], nil} end,
               :config
             )

    state = state_with_tab_bar(TabBar.new(Tab.new_file(1, "main.ex")))
    data = Data.from_state(state)

    assert {:buffer, buffer_data} = Data.with_modeline_segments(data, state.theme, table)
    assert %{left: left, right: right} = buffer_data.modeline_segments

    assert Enum.any?(left ++ right, fn {_name, text, _fg, _bg, _opts, _target} ->
             text == " GUI_ONLY "
           end)
  end

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

  test "agent status message count uses user turns instead of raw transcript entries" do
    {:ok, session} = MetadataSession.start_link(message_count: 4, turn_count: 1)

    tb = TabBar.new(Tab.new_file(1, "main.ex"))
    {tb, agent_tab} = TabBar.add(tb, :agent, "Agent")

    tb =
      tb
      |> TabBar.switch_to(agent_tab.id)
      |> TabBar.update_tab(agent_tab.id, &Tab.set_session(&1, session))

    workspace_id = TabBar.active_workspace_id(tb)
    tb = TabBar.update_workspace(tb, workspace_id, &WorkspaceModel.set_session(&1, session))

    state = state_with_agent_window(tb)

    assert {:agent, data} = Data.from_state(state)
    assert data.message_count == 1
  end

  test "threads active_tool_name from state into modeline data and clears it on status changes" do
    {state, _buf} = state_with_buffer("hello", nil, :elixir)

    state =
      state
      |> AgentAccess.update_agent(&AgentState.set_status(&1, :tool_executing))
      |> AgentAccess.update_agent(&AgentState.set_active_tool_name(&1, "read_file"))

    data = Data.from_state(state) |> Data.to_modeline_data()

    assert data.agent_status == :tool_executing
    assert data.active_tool_name == "read_file"

    state = AgentAccess.update_agent(state, &AgentState.set_status(&1, :idle))
    idle_data = Data.from_state(state) |> Data.to_modeline_data()

    assert idle_data.agent_status == :idle
    assert idle_data.active_tool_name == nil
  end

  test "uses options server values when no active buffer is available" do
    options = start_supervised!({Options, name: nil})
    {:ok, _} = Options.set_for_filetype(options, :text, :indent_with, :tabs)
    {:ok, _} = Options.set_for_filetype(options, :text, :tab_width, 4)

    state = %EditorState{
      port_manager: self(),
      options_server: options,
      workspace: %SessionState{viewport: Viewport.new(24, 80)},
      shell_runtime:
        Runtime.new(Registry.get(:traditional), %MingaEditor.Shell.Traditional.State{})
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

  test "active buffer merge conflict count appears in modeline data" do
    {state, _buf} =
      state_with_buffer("<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> branch", nil, :text)

    data = Data.from_state(state) |> Data.to_modeline_data()

    assert data.merge_conflict_count == 1
  end

  test "active buffer merge conflict count uses tracked git buffer cache when present" do
    root = Path.join(System.tmp_dir!(), "status-bar-git-#{System.unique_integer([:positive])}")
    GitStub.ensure_table()
    GitStub.set_root(root, root)
    on_exit(fn -> GitStub.clear(root) end)

    {state, buf} = state_with_buffer("resolved", nil, :text)

    {:ok, git_pid} =
      start_supervised(
        {GitBuffer,
         git_root: root,
         file_path: Path.join(root, "conflict.txt"),
         initial_content: "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> branch"}
      )

    register_tracked_buffer(buf, git_pid)

    data = Data.from_state(state) |> Data.to_modeline_data()

    assert data.merge_conflict_count == 1
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
      workspace: %SessionState{viewport: Viewport.new(24, 80)},
      shell_runtime:
        Runtime.new(
          Registry.get(:traditional),
          %MingaEditor.Shell.Traditional.State{tab_bar: tab_bar}
        )
    }
  end

  defp state_with_agent_window(tab_bar) do
    %EditorState{
      port_manager: self(),
      workspace: %SessionState{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{list: [], active_index: 0, active: nil},
        windows: %Windows{
          tree: WindowTree.new(1),
          map: %{1 => Window.new_agent_chat(1, 24, 80)},
          active: 1,
          next_id: 2
        }
      },
      shell_runtime:
        Runtime.new(
          Registry.get(:traditional),
          %MingaEditor.Shell.Traditional.State{tab_bar: tab_bar}
        )
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
        shell_runtime:
          Runtime.new(Registry.get(:traditional), %MingaEditor.Shell.Traditional.State{})
      }

    {state, buf}
  end

  defp workspace_with_buffer(buf) do
    %SessionState{
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
    # Use an isolated events registry so edits don't broadcast to the global
    # Git.Tracker, which would race with register_tracked_buffer and overwrite
    # the GitBuffer's conflict state with the buffer's (conflict-free) content.
    registry = :"data_test_events_#{System.unique_integer([:positive])}"

    buf =
      start_supervised!(
        {BufferProcess, [content: "", filetype: filetype, events_registry: registry]}
      )

    :ok = BufferProcess.insert_text(buf, content)
    buf
  end

  defp register_tracked_buffer(buffer, git_pid) do
    Minga.Git.Tracker.put_mapping(buffer, git_pid)
    on_exit(fn -> Minga.Git.Tracker.remove_mapping(buffer) end)
  end

  defp modeline_text(%{left: left, right: right}) do
    Enum.map_join(left ++ right, fn {_name, text, _fg, _bg, _opts, _target} -> text end)
  end

  defp handle(session_id, task) do
    Handle.new(session_id: session_id, pid: self(), task: task, started_at: DateTime.utc_now())
  end
end
