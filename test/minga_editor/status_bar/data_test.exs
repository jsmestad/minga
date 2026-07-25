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
  alias MingaEditor.Shell.Traditional.WhichKeyWorkflow
  alias MingaEditor.StatusBar.Data
  alias Minga.RenderModel.UI.StatusBar.Cursor, as: StatusCursor
  alias Minga.RenderModel.UI.StatusBar.Data, as: SemanticStatusData
  alias Minga.RenderModel.UI.StatusBar.File, as: StatusFile
  alias MingaEditor.StatusBar.Data.Agent, as: StatusAgent
  alias MingaEditor.StatusBar.Data.Buffer, as: StatusBuffer
  alias MingaEditor.StatusBar.Data.Common
  alias MingaEditor.Shell.Registry
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Feedback
  alias MingaEditor.State.OperationFeedback
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
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

    {operation_feedback, operation} =
      OperationFeedback.start(
        state.feedback.operation_feedback,
        :lsp_references,
        "main.ex",
        "Finding references..."
      )

    state = %{
      state
      | feedback: Feedback.accept_operation_feedback(state.feedback, operation_feedback)
    }

    assert %Data{common: %Common{} = common, content: %StatusBuffer{}} = Data.from_state(state)
    assert common.selected_operation == operation
    assert common.notice == nil
  end

  test "from_state leaves GUI modeline segments detached by default" do
    state = state_with_tab_bar(TabBar.new(Tab.new_file(1, "main.ex")))
    data = Data.from_state(state)

    assert %Data{
             common: %Common{status: %SemanticStatusData{} = status},
             content: %StatusBuffer{}
           } = data

    assert status.modeline_segments == nil
  end

  describe "pending_keys (showcmd)" do
    test "is empty in a fresh normal-mode state" do
      state = state_with_tab_bar(TabBar.new(Tab.new_file(1, "main.ex")))
      %Data{common: %Common{status: status}, content: %StatusBuffer{}} = Data.from_state(state)
      assert status.pending_keys == ""
    end

    test "echoes an accumulated count from FSM state" do
      state =
        state_with_tab_bar(TabBar.new(Tab.new_file(1, "main.ex")))
        |> then(fn state ->
          then(state, fn state ->
            %{
              state
              | workspace:
                  then(
                    state.workspace,
                    &MingaEditor.Session.State.set_editing(
                      &1,
                      MingaEditor.VimState.set_mode_state(&1.editing, %{
                        state.workspace.editing.mode_state
                        | count: 2
                      })
                    )
                  )
            }
          end)
        end)

      %Data{common: %Common{status: status}, content: %StatusBuffer{}} = Data.from_state(state)
      assert status.pending_keys == "2"
    end

    test "prefixes the active register selection" do
      state =
        state_with_tab_bar(TabBar.new(Tab.new_file(1, "main.ex")))
        |> MingaEditor.Editing.set_active_register("a")

      %Data{common: %Common{status: status}, content: %StatusBuffer{}} = Data.from_state(state)
      assert status.pending_keys == "\"a"
    end

    test "echoes a pending operator in operator-pending mode" do
      op_state = %Minga.Mode.OperatorPendingState{operator: :delete}

      state =
        state_with_tab_bar(TabBar.new(Tab.new_file(1, "main.ex")))
        |> then(fn state ->
          %{
            state
            | workspace:
                then(state.workspace, fn workspace ->
                  MingaEditor.Session.State.transition_mode(
                    workspace,
                    :operator_pending,
                    op_state
                  )
                end)
          }
        end)

      %Data{common: %Common{status: status}, content: %StatusBuffer{}} = Data.from_state(state)
      assert status.pending_keys == "d"
    end

    test "composes the register prefix with operator-pending FSM state" do
      op_state = %Minga.Mode.OperatorPendingState{operator: :delete, op_count: 2}

      state =
        state_with_tab_bar(TabBar.new(Tab.new_file(1, "main.ex")))
        |> MingaEditor.Editing.set_active_register("a")
        |> then(fn state ->
          %{
            state
            | workspace:
                then(state.workspace, fn workspace ->
                  MingaEditor.Session.State.transition_mode(
                    workspace,
                    :operator_pending,
                    op_state
                  )
                end)
          }
        end)

      %Data{common: %Common{status: status}, content: %StatusBuffer{}} = Data.from_state(state)
      assert status.pending_keys == "\"a2d"
    end

    test "clears when the which-key popup is showing" do
      state =
        state_with_tab_bar(TabBar.new(Tab.new_file(1, "main.ex")))
        |> then(fn state ->
          then(state, fn state ->
            %{
              state
              | workspace:
                  then(
                    state.workspace,
                    &MingaEditor.Session.State.set_editing(
                      &1,
                      MingaEditor.VimState.set_mode_state(&1.editing, %{
                        state.workspace.editing.mode_state
                        | count: 2
                      })
                    )
                  )
            }
          end)
        end)
        |> WhichKeyWorkflow.begin(%{}, [])

      state = WhichKeyWorkflow.reveal(state, state.shell_runtime.state.whichkey.generation)
      %Data{common: %Common{status: status}, content: %StatusBuffer{}} = Data.from_state(state)
      assert status.pending_keys == ""
    end
  end

  test "with_modeline_segments preserves agent status command output" do
    state = state_with_tab_bar(TabBar.new(Tab.new_file(1, "main.ex")))
    state = MingaEditor.Shell.Traditional.Workflow.install_agent_status(state, :thinking)
    %Data{common: %Common{} = common, content: %StatusBuffer{}} = data = Data.from_state(state)
    data = %{data | common: %{common | agent_status_command: "sonnet | thinking"}}

    assert %Data{
             common: %Common{status: %SemanticStatusData{modeline_segments: segments}},
             content: %StatusBuffer{}
           } = Data.with_modeline_segments(data, state.appearance.theme)

    text = modeline_text(segments)

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
               fn ctx ->
                 text =
                   if ctx.data.diagnostic_counts == nil, do: " NIL_DIAGS ", else: " ZERO_DIAGS "

                 {text, ctx.info_fg, ctx.bar_bg, [], nil}
               end,
               :config
             )

    state = state_with_tab_bar(TabBar.new(Tab.new_file(1, "main.ex")))
    data = Data.from_state(state)

    assert %Data{
             common: %Common{
               status: %SemanticStatusData{modeline_segments: %{left: left, right: right}}
             },
             content: same_content
           } = Data.with_modeline_segments(data, state.appearance.theme, table)

    assert same_content == data.content

    assert Enum.find_value(left ++ right, fn
             {:status_bar_data_modeline_test, text, _fg, _bg, _opts, _target} -> text
             _segment -> nil
           end) == " NIL_DIAGS "
  end

  test "multi-buffer modeline uses typed buffer index and count from common data" do
    first = start_buffer("first", :text)
    second = start_buffer("second", :text)

    state =
      state_with_tab_bar(TabBar.new(Tab.new_file(1, "second.txt")))
      |> then(fn %{workspace: %SessionState{} = workspace} = state ->
        %{
          state
          | workspace: %SessionState{
              workspace
              | buffers: %Buffers{list: [first, second], active_index: 1, active: second},
                windows: %Windows{
                  tree: WindowTree.new(1),
                  map: %{1 => Window.new(1, second, 24, 80)},
                  active: 1,
                  next_id: 2
                }
            }
        }
      end)

    data = Data.from_state(state)
    modeline_data = Data.to_modeline_data(data)

    assert %Data{common: %Common{buf_index: 2, buf_count: 2}, content: %StatusBuffer{}} = data
    assert %{buf_index: 2, buf_count: 2} = modeline_data

    segmented = Data.with_modeline_segments(data, state.appearance.theme)

    assert %Data{
             common: %Common{status: %SemanticStatusData{modeline_segments: segments}},
             content: %StatusBuffer{}
           } = segmented

    assert String.contains?(modeline_text(segments), "[2/2]")
  end

  test "projects running background subagent count and active label" do
    handle1 = handle("session-2", "tests")
    handle2 = handle("session-3", "docs")

    tb = TabBar.new(Tab.new_file(1, "main.ex"))
    {tb, tab1} = TabBar.add(tb, :agent, "subagent tests")

    tab1 =
      tab1
      |> Tab.set_session(handle1.pid)
      |> Tab.set_agent_status(:thinking)
      |> Tab.mark_background_subagent(handle1)

    tb = TabBar.accept_tab(tb, tab1)
    {tb, tab2} = TabBar.add(tb, :agent, "subagent docs")

    tab2 =
      tab2
      |> Tab.set_session(handle2.pid)
      |> Tab.set_agent_status(:idle)
      |> Tab.mark_background_subagent(handle2)

    tb = TabBar.accept_tab(tb, tab2)

    state = state_with_tab_bar(TabBar.switch_to(tb, tab1.id))
    data = Data.from_state(state) |> Data.to_modeline_data()

    assert data.background_subagent_count == 1
    assert data.active_background_subagent_label == "session-2: tests"
  end

  test "agent status message count uses user turns instead of raw transcript entries" do
    {:ok, session} = MetadataSession.start_link(message_count: 4, turn_count: 1)

    tb = TabBar.new(Tab.new_file(1, "main.ex"))
    {tb, workspace} = TabBar.add_workspace(tb, "Agent", session)
    {tb, agent_tab} = TabBar.add(tb, :agent, "Agent")

    tb =
      tb
      |> TabBar.accept_tab(Tab.set_group(agent_tab, workspace.id))
      |> TabBar.switch_to(agent_tab.id)
      |> TabBar.set_tab_session(agent_tab.id, session)

    state = state_with_agent_window(tb)

    assert %Data{content: %StatusAgent{} = agent} = Data.from_state(state)
    assert agent.message_count == 1
  end

  test "agent status data reuses the same background buffer semantics as buffer status data" do
    {state, _buf} = state_with_buffer("héllo\nworld", nil, :elixir)

    state =
      state
      |> MingaEditor.Shell.Traditional.Workflow.install_agent_status(:thinking)
      |> MingaEditor.Shell.Traditional.Workflow.install_agent_tool("read_file")

    assert %Data{common: buffer_common, content: %StatusBuffer{}} = Data.from_state(state)

    assert %Data{common: agent_common, content: %StatusAgent{} = agent_data} =
             Data.from_state(with_agent_chat_window(state))

    assert agent_common == %{
             buffer_common
             | agent_theme_colors: MingaEditor.UI.Theme.agent_theme(state.appearance.theme)
           }

    assert {agent_data.model_name, agent_data.session_status, agent_data.message_count} ==
             {"unknown", :thinking, 0}
  end

  test "agent no-buffer fallback stays explicit while launchpad buffer fallback stays empty" do
    buffer_state =
      put_in(
        state_with_tab_bar(TabBar.new(Tab.new_file(1, "main.ex"))).workspace.launchpad,
        MingaEditor.State.Launchpad.new(session_file_count: 0, recents: [])
      )

    assert %Data{
             common: %Common{status: %SemanticStatusData{file: %StatusFile{name: ""}}},
             content: %StatusBuffer{}
           } = Data.from_state(buffer_state)

    agent_data = Data.from_state(with_agent_chat_window(buffer_state))

    assert %Data{
             common: %Common{
               status: %SemanticStatusData{
                 file: %StatusFile{name: "[no file]", filetype: :text},
                 cursor: %StatusCursor{line: 0, col: 0, line_count: 1}
               }
             },
             content: %StatusAgent{}
           } = agent_data

    assert agent_data.common.raw_diagnostic_counts == nil
    assert agent_data.common.status.diagnostics.counts == {0, 0, 0, 0}
    assert Data.to_modeline_data(agent_data).diagnostic_counts == nil
  end

  test "threads active_tool_name from state into modeline data and clears it on status changes" do
    {state, _buf} = state_with_buffer("hello", nil, :elixir)

    state =
      state
      |> MingaEditor.Shell.Traditional.Workflow.install_agent_status(:tool_executing)
      |> MingaEditor.Shell.Traditional.Workflow.install_agent_tool("read_file")

    data = Data.from_state(state) |> Data.to_modeline_data()

    assert data.agent_status == :tool_executing
    assert data.active_tool_name == "read_file"

    state = MingaEditor.Shell.Traditional.Workflow.install_agent_status(state, :idle)
    idle_data = Data.from_state(state) |> Data.to_modeline_data()

    assert idle_data.agent_status == :idle
    assert idle_data.active_tool_name == nil
  end

  test "uses options server values when no active buffer is available" do
    options = start_supervised!({Options, name: nil})
    {:ok, _} = Options.set_for_filetype(options, :text, :indent_with, :tabs)
    {:ok, _} = Options.set_for_filetype(options, :text, :tab_width, 4)

    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      interaction: %MingaEditor.State.Interaction{options_server: options},
      workspace: %SessionState{},
      shell_runtime:
        Runtime.new(Registry.get(:traditional), %MingaEditor.Shell.Traditional.State{})
    }

    %Data{common: %Common{status: status}, content: %StatusBuffer{}} = Data.from_state(state)

    assert status.indent.type == :tabs
    assert status.indent.size == 4
  end

  test "buffer-local indent options override filetype defaults" do
    options = start_supervised!({Options, name: nil})
    {:ok, _} = Options.set_for_filetype(options, :elixir, :indent_with, :spaces)
    {:ok, _} = Options.set_for_filetype(options, :elixir, :tab_width, 2)

    {state, buf} = state_with_buffer("hello", options, :elixir)
    BufferProcess.set_option(buf, :indent_with, :tabs)
    BufferProcess.set_option(buf, :tab_width, 4)

    %Data{common: %Common{status: status}, content: %StatusBuffer{}} = Data.from_state(state)

    assert status.indent.type == :tabs
    assert status.indent.size == 4
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
      then(state, fn state ->
        %{
          state
          | workspace:
              then(state.workspace, fn workspace ->
                MingaEditor.Session.State.transition_mode(workspace, :visual, %VisualState{
                  visual_type: :char,
                  visual_anchor: {0, 0}
                })
              end)
        }
      end)

    %Data{common: %Common{status: status}, content: %StatusBuffer{}} =
      data = Data.from_state(state)

    assert status.selection.mode == :chars
    assert status.selection.size == 5
    assert Data.to_modeline_data(data).selection_info == {:chars, 5}
  end

  test "visual line selection reports selected line count" do
    {state, _buf} = state_with_buffer("one\ntwo\nthree", nil, :text)

    state =
      then(state, fn state ->
        %{
          state
          | workspace:
              then(state.workspace, fn workspace ->
                MingaEditor.Session.State.transition_mode(workspace, :visual, %VisualState{
                  visual_type: :line,
                  visual_anchor: {0, 0}
                })
              end)
        }
      end)

    %Data{common: %Common{status: status}, content: %StatusBuffer{}} =
      data = Data.from_state(state)

    assert status.selection.mode == :lines
    assert status.selection.size == 3
    assert Data.to_modeline_data(data).selection_info == {:lines, 3}
  end

  defp state_with_tab_bar(tab_bar) do
    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: %SessionState{},
      shell_runtime:
        Runtime.new(
          Registry.get(:traditional),
          %MingaEditor.Shell.Traditional.State{tab_bar: tab_bar}
        )
    }
  end

  defp state_with_agent_window(tab_bar) do
    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: %SessionState{
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
        frontend: %MingaEditor.State.Frontend{port_manager: self()},
        interaction: %MingaEditor.State.Interaction{options_server: options_server},
        workspace: workspace,
        shell_runtime:
          Runtime.new(Registry.get(:traditional), %MingaEditor.Shell.Traditional.State{})
      }

    {state, buf}
  end

  defp workspace_with_buffer(buf) do
    %SessionState{
      buffers: %Buffers{list: [buf], active_index: 0, active: buf},
      windows: %Windows{
        tree: WindowTree.new(1),
        map: %{1 => Window.new(1, buf, 24, 80)},
        active: 1,
        next_id: 2
      }
    }
  end

  defp with_agent_chat_window(state) do
    put_in(state.workspace.windows, %{
      state.workspace.windows
      | map: %{1 => Window.new_agent_chat(1, 24, 80)},
        active: 1
    })
  end

  defp start_buffer(content, filetype) do
    # Use an isolated events registry so edits don't broadcast to the global
    # Git.Tracker, which would race with register_tracked_buffer and overwrite
    # the GitBuffer's conflict state with the buffer's (conflict-free) content.
    registry = :"data_test_events_#{System.unique_integer([:positive])}"

    buf =
      start_supervised!(
        {BufferProcess, [content: "", filetype: filetype, events_registry: registry]},
        id: {:data_test_buffer, System.unique_integer([:positive])}
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
