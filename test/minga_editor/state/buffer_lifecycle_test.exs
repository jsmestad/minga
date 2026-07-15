defmodule MingaEditor.State.BufferLifecycleTest do
  @moduledoc """
  Pure-function tests for buffer lifecycle operations on `EditorState`.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Events
  alias Minga.Project.FileRef
  alias MingaEditor.Agent.UIState
  alias MingaEditor.BufferLifecycle
  alias MingaEditor.Shell.Registry
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Git, as: GitState
  alias MingaEditor.State.Parser, as: ParserState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.State.Workspace
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.Window.Content
  alias MingaEditor.WindowTree
  alias MingaEditor.Session.State, as: SessionState

  import MingaEditor.RenderPipeline.TestHelpers

  @spec state_with_file_tab(keyword()) :: EditorState.t()
  defp state_with_file_tab(opts \\ []) do
    state = base_state(opts)
    tab = Tab.new_file(1, "test.ex")

    tb =
      TabBar.new(tab)
      |> TabBar.update_context(1, MingaEditor.State.Tab.Context.snapshot(state.workspace))

    then(state, fn root ->
      shell_state =
        MingaEditor.Shell.Traditional.State.install_tab_bar(
          MingaEditor.Shell.Runtime.state(root.shell_runtime),
          tb
        )

      %{
        root
        | shell_runtime:
            MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
      }
    end)
  end

  @spec state_with_file_tab_for_path(String.t(), String.t()) :: {EditorState.t(), pid()}
  defp state_with_file_tab_for_path(path, content) do
    buf = start_file_buffer(path, content)
    state = state_for_buffer(buf)
    tab = Tab.new_file(1, Path.basename(path))

    tb =
      TabBar.new(tab)
      |> TabBar.update_context(1, MingaEditor.State.Tab.Context.snapshot(state.workspace))

    {then(state, fn root ->
       shell_state =
         MingaEditor.Shell.Traditional.State.install_tab_bar(
           MingaEditor.Shell.Runtime.state(root.shell_runtime),
           tb
         )

       %{
         root
         | shell_runtime:
             MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
       }
     end), buf}
  end

  @spec state_with_agent_tab() :: EditorState.t()
  defp state_with_agent_tab do
    agent_window = Window.new_agent_chat(1, 24, 80)

    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      shell_runtime: resolved_traditional_runtime(),
      workspace: %SessionState{
        viewport: Viewport.new(24, 80),
        editing: VimState.new(),
        keymap_scope: :agent,
        buffers: %Buffers{active: nil, list: [], active_index: 0},
        windows: %Windows{
          tree: WindowTree.new(1),
          map: %{1 => agent_window},
          active: 1,
          next_id: 2
        }
      }
    }

    tb =
      TabBar.new(Tab.new_agent(1, "Agent"))
      |> TabBar.update_context(1, MingaEditor.State.Tab.Context.snapshot(state.workspace))

    then(state, fn root ->
      shell_state =
        MingaEditor.Shell.Traditional.State.install_tab_bar(
          MingaEditor.Shell.Runtime.state(root.shell_runtime),
          tb
        )

      %{
        root
        | shell_runtime:
            MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
      }
    end)
  end

  @spec start_buffer(String.t()) :: pid()
  defp start_buffer(content) do
    {:ok, pid} = BufferProcess.start_link(content: content)
    pid
  end

  @spec start_file_buffer(String.t(), String.t()) :: pid()
  defp start_file_buffer(path, content) do
    File.write!(path, content)
    {:ok, pid} = BufferProcess.start_link(file_path: path)
    pid
  end

  describe "register_buffer/3" do
    test "adds buffers with no tab bar, opens file tabs, previews without overwriting context, and avoids duplicate monitors" do
      no_tab = base_state()
      new_buf = start_buffer("new file")

      {new_state, result} =
        register_buffer(no_tab, new_buf, no_tab.buffer_lifecycle.buffer_add_context)

      assert new_buf in new_state.workspace.buffers.list
      assert new_state.workspace.buffers.active == new_buf
      assert result == {:monitor, new_buf}

      state = state_with_file_tab()
      original_buf = state.workspace.buffers.active
      opened_buf = start_buffer("opened")
      {opened, result} = register_buffer(state, opened_buf, :open)
      tb = opened.shell_runtime.state.tab_bar
      assert result == {:monitor, opened_buf}
      assert TabBar.count(tb) == 2
      assert tb.active_id == 2
      assert %Buffers{active: ^original_buf} = TabBar.get(tb, 1).context.buffers
      assert %Buffers{active: ^opened_buf} = TabBar.get(tb, 2).context.buffers
      assert opened.workspace.buffers.active == opened_buf

      preview_buf = start_buffer("preview")

      {previewed, {:monitor, ^preview_buf}} =
        register_buffer(state, preview_buf, :preview)

      assert TabBar.count(previewed.shell_runtime.state.tab_bar) == 1
      assert previewed.workspace.buffers.active == preview_buf

      assert %Buffers{active: ^original_buf} =
               TabBar.get(previewed.shell_runtime.state.tab_bar, 1).context.buffers

      assert previewed.buffer_lifecycle.buffer_add_context == :open

      duplicate = MingaEditor.Handlers.BufferRegistry.add_buffer(state, opened_buf)

      {switched_back, :already_registered} =
        register_buffer(duplicate, original_buf, duplicate.buffer_lifecycle.buffer_add_context)

      assert switched_back.workspace.buffers.active == original_buf
    end

    test "focused registration workflow creates the monitor requested by the pure transition" do
      state = base_state()
      buffer = start_buffer("workflow monitored")

      registered = MingaEditor.Handlers.BufferRegistry.add_buffer(state, buffer)

      assert is_reference(registered.buffer_lifecycle.buffer_monitors[buffer])
      assert buffer in registered.workspace.buffers.list
    end

    test "opening from an agent tab snapshots agent state, creates a file tab, switches scope, and stops the spinner" do
      state = state_with_agent_tab()
      file_buf = start_buffer("file content")

      {new_state, {:monitor, ^file_buf}} =
        register_buffer(state, file_buf, :open)

      tb = new_state.shell_runtime.state.tab_bar
      agent_tab = TabBar.get(tb, 1)
      file_tab = TabBar.active(tb)
      window = active_window(new_state)

      assert TraditionalState.agent(new_state.shell_runtime.state).spinner_timer == nil
      assert TabBar.count(tb) == 2
      assert agent_tab.kind == :agent
      assert %Buffers{active: nil, list: []} = agent_tab.context.buffers
      assert agent_tab.context.keymap_scope == :agent
      assert file_tab.kind == :file
      assert %Buffers{active: ^file_buf} = file_tab.context.buffers
      assert file_tab.context.keymap_scope == :editor
      assert new_state.workspace.keymap_scope == :editor
      assert new_state.workspace.buffers.active == file_buf
      assert Content.buffer?(window.content)
    end

    @tag :tmp_dir
    test "file identity uses real paths, not just basenames, and existing tabs are reactivated without monitor effects",
         %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "one.ex")
      path2 = Path.join(tmp_dir, "two.ex")
      {state, buf1} = state_with_file_tab_for_path(path1, "one")
      buf2 = start_file_buffer(path2, "two")

      {state, {:monitor, ^buf2}} = register_buffer(state, buf2, :open)

      {reactivated, :already_registered} =
        register_buffer(state, buf1, :open)

      assert reactivated.shell_runtime.state.tab_bar.active_id == 1
      assert reactivated.workspace.buffers.active == buf1

      assert %Buffers{active: ^buf1} =
               TabBar.get(reactivated.shell_runtime.state.tab_bar, 1).context.buffers

      assert %Buffers{active: ^buf2} =
               TabBar.get(reactivated.shell_runtime.state.tab_bar, 2).context.buffers

      dir1 = Path.join(tmp_dir, "one")
      dir2 = Path.join(tmp_dir, "two")
      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2)
      same1 = Path.join(dir1, "same.ex")
      same2 = Path.join(dir2, "same.ex")
      {state, same_buf1} = state_with_file_tab_for_path(same1, "one")
      same_buf2 = start_file_buffer(same2, "two")

      {distinct, {:monitor, ^same_buf2}} =
        register_buffer(state, same_buf2, :open)

      assert TabBar.count(distinct.shell_runtime.state.tab_bar) == 2
      assert TabBar.get(distinct.shell_runtime.state.tab_bar, 1).label == "same.ex"
      assert TabBar.get(distinct.shell_runtime.state.tab_bar, 2).label == "same.ex"

      assert %Buffers{active: ^same_buf1} =
               TabBar.get(distinct.shell_runtime.state.tab_bar, 1).context.buffers

      assert %Buffers{active: ^same_buf2} =
               TabBar.get(distinct.shell_runtime.state.tab_bar, 2).context.buffers
    end

    test "agent chat windows without tab bars keep their content when a file buffer is added" do
      agent_window = Window.new_agent_chat(1, 24, 80)

      state = %EditorState{
        frontend: %MingaEditor.State.Frontend{port_manager: self()},
        workspace: %SessionState{
          viewport: Viewport.new(24, 80),
          editing: VimState.new(),
          buffers: %Buffers{active: nil, list: [], active_index: 0},
          windows: %Windows{
            tree: WindowTree.new(1),
            map: %{1 => agent_window},
            active: 1,
            next_id: 2
          }
        }
      }

      file_buf = start_buffer("file content")

      {new_state, {:monitor, ^file_buf}} =
        register_buffer(state, file_buf, state.buffer_lifecycle.buffer_add_context)

      window = active_window(new_state)

      assert file_buf in new_state.workspace.buffers.list
      assert new_state.workspace.buffers.active == file_buf
      assert Content.agent_chat?(window.content)
      assert Content.buffer_pid(window.content) == nil
    end
  end

  describe "BufferActivation.activate/2" do
    test "open switches refresh active file tab context, while preview switches keep the original context" do
      state = state_with_file_tab()
      original_buf = state.workspace.buffers.active
      other_buf = start_buffer("other")
      state = with_buffer_pool(state, [original_buf, other_buf])

      opened = MingaEditor.BufferActivation.activate(state, 1)
      assert opened.workspace.buffers.active == other_buf

      assert %Buffers{active: ^other_buf} =
               TabBar.active(opened.shell_runtime.state.tab_bar).context.buffers

      preview_buf = start_buffer("preview")

      preview_state =
        state
        |> with_buffer_pool([original_buf, preview_buf])
        |> then(fn state ->
          %{
            state
            | buffer_lifecycle:
                MingaEditor.State.BufferLifecycle.expect_buffer(
                  state.buffer_lifecycle,
                  :preview
                )
          }
        end)

      previewed = MingaEditor.BufferActivation.activate(preview_state, 1)
      assert previewed.workspace.buffers.active == preview_buf
      assert previewed.buffer_lifecycle.buffer_add_context == :open

      assert %Buffers{active: ^original_buf} =
               TabBar.active(previewed.shell_runtime.state.tab_bar).context.buffers
    end
  end

  describe "remove_buffer/2" do
    test "closing active, only, inactive, and special buffers updates buffers and monitor refs" do
      state = base_state()
      buf1 = state.workspace.buffers.active
      buf2 = start_buffer("second")

      state =
        state
        |> MingaEditor.Handlers.BufferRegistry.add_buffer(buf2)
        |> MingaEditor.Handlers.BufferRegistry.monitor_buffer(buf1)
        |> MingaEditor.Handlers.BufferRegistry.monitor_buffer(buf2)

      closed_active = EditorState.remove_buffer(state, buf2)
      refute buf2 in closed_active.workspace.buffers.list
      assert closed_active.workspace.buffers.active == buf1
      refute Map.has_key?(closed_active.buffer_lifecycle.buffer_monitors, buf2)

      buf3 = start_buffer("third")

      inactive_state =
        state
        |> MingaEditor.Handlers.BufferRegistry.add_buffer(buf3)
        |> MingaEditor.Handlers.BufferRegistry.monitor_buffer(buf3)

      closed_inactive = EditorState.remove_buffer(inactive_state, buf1)
      assert closed_inactive.workspace.buffers.active == buf3
      refute buf1 in closed_inactive.workspace.buffers.list

      only_state = base_state()
      only_buf = only_state.workspace.buffers.active
      only_state = MingaEditor.Handlers.BufferRegistry.monitor_buffer(only_state, only_buf)
      closed_only = EditorState.remove_buffer(only_state, only_buf)
      assert closed_only.workspace.buffers.list == []
      assert closed_only.workspace.buffers.active == nil
      refute Map.has_key?(closed_only.buffer_lifecycle.buffer_monitors, only_buf)
    end

    test "closing buffers scrubs inactive tab snapshots, including tabs whose only buffer died" do
      buf_a = start_buffer("file A")
      buf_b = start_buffer("file B")

      state =
        state_for_buffer(buf_a, list: [buf_a, buf_b])
        |> MingaEditor.Handlers.BufferRegistry.monitor_buffers([buf_a, buf_b])

      {state, tab_b} = state_with_inactive_tab_buffer(state, buf_b)

      new_state = EditorState.remove_buffer(state, buf_b)
      tab_b_after = TabBar.get(new_state.shell_runtime.state.tab_bar, tab_b.id)
      refute buf_b in tab_b_after.context.buffers.list
      assert tab_b_after.context.buffers.active != buf_b

      restored_ws = SessionState.restore_tab_context(new_state.workspace, tab_b_after.context)
      refute buf_b in restored_ws.buffers.list
      assert restored_ws.buffers.active != buf_b

      only = start_buffer("only buffer")

      only_state =
        state_for_buffer(only) |> MingaEditor.Handlers.BufferRegistry.monitor_buffer(only)

      {only_state, only_tab} = state_with_inactive_tab_buffer(only_state, only)
      closed_only = EditorState.remove_buffer(only_state, only)
      only_tab_after = TabBar.get(closed_only.shell_runtime.state.tab_bar, only_tab.id)
      assert only_tab_after.context.buffers.list == []
      assert only_tab_after.context.buffers.active == nil
    end

    test "removal scrubs parser git prompt tab and workspace owners atomically" do
      retired = start_buffer("retired")
      survivor = start_buffer("survivor")
      file_ref = FileRef.from_buffer(retired, "retired")
      prompt_ui = UIState.new() |> UIState.attach_prompt_buffer(retired)

      workspace =
        state_for_buffer(retired, list: [retired, survivor]).workspace
        |> SessionState.set_agent_ui(prompt_ui)

      active_tab =
        Tab.new_file(1, "retired")
        |> Tab.set_file_ref(file_ref)
        |> Tab.set_context(MingaEditor.State.Tab.Context.snapshot(workspace))

      inactive_tab =
        Tab.new_file(2, "inactive")
        |> Tab.set_file_ref(file_ref)
        |> Tab.set_context(MingaEditor.State.Tab.Context.snapshot(workspace))

      tab_bar = %TabBar{tabs: [active_tab, inactive_tab], active_id: 1, next_id: 3}
      {tab_bar, agent_workspace} = TabBar.add_workspace(tab_bar, "Agent")

      tab_bar =
        tab_bar
        |> TabBar.add_workspace_file(0, file_ref)
        |> TabBar.set_workspace_active_file(0, file_ref)
        |> TabBar.set_workspace_agent_ui(0, prompt_ui)
        |> TabBar.add_workspace_file(agent_workspace.id, file_ref)
        |> TabBar.set_workspace_active_file(agent_workspace.id, file_ref)
        |> TabBar.set_workspace_agent_ui(agent_workspace.id, prompt_ui)

      shell_state =
        TraditionalState.install_tab_bar(
          MingaEditor.Shell.Runtime.state(resolved_traditional_runtime()),
          tab_bar
        )

      parser =
        ParserState.accept_injection_ranges(%ParserState{}, %{retired => []})

      info = %{
        source_buf: retired,
        git_root: "/tmp",
        rel_path: "retired",
        staged: false,
        line_metadata: [],
        hunk_lines: []
      }

      git =
        %GitState{}
        |> GitState.register_diff_view(retired, info)
        |> GitState.register_diff_view(survivor, info)

      state = %EditorState{
        workspace: workspace,
        shell_runtime:
          MingaEditor.Shell.Runtime.install_traditional_state(
            resolved_traditional_runtime(),
            shell_state
          ),
        parser: parser,
        git: git
      }

      removed = EditorState.remove_buffer(state, retired)
      tab_bar = removed.shell_runtime.state.tab_bar

      assert removed.workspace.agent_ui.panel.prompt_buffer == nil
      refute Map.has_key?(removed.parser.injection_ranges, retired)
      assert removed.git.diff_views == %{}

      Enum.each(tab_bar.tabs, fn tab ->
        refute retired in tab.context.buffers.list
        assert tab.context.agent_ui.panel.prompt_buffer == nil
        assert tab.file_ref == nil
      end)

      Enum.each(tab_bar.workspaces, fn %Workspace{} = owner ->
        refute Enum.any?(owner.files, &FileRef.equal?(&1, file_ref))
        assert owner.active_file == nil
        assert is_nil(owner.agent_ui) or owner.agent_ui.panel.prompt_buffer == nil
      end)
    end

    @tag :tmp_dir
    test "post-command lifecycle does not duplicate source-owned save events", %{
      tmp_dir: tmp_dir
    } do
      active_path = Path.join(tmp_dir, "active.ex")
      saved_path = Path.join(tmp_dir, "saved.ex")
      File.write!(active_path, "active")
      File.write!(saved_path, "saved")

      active_buf = start_file_buffer(active_path, "active")
      saved_buf = start_file_buffer(saved_path, "saved")
      state = state_for_buffer(active_buf)

      Events.subscribe(:buffer_saved)
      on_exit(fn -> Events.unsubscribe(:buffer_saved) end)

      assert %EditorState{} = BufferLifecycle.lsp_after_save(state, :save, saved_buf)

      refute_receive {:minga_event, :buffer_saved,
                      %Minga.Events.BufferEvent{buffer: ^saved_buf, path: ^saved_path}}

      refute_receive {:minga_event, :buffer_saved,
                      %Minga.Events.BufferEvent{buffer: ^active_buf, path: ^active_path}}
    end
  end

  @spec register_buffer(EditorState.t(), pid(), MingaEditor.Shell.buffer_add_context()) ::
          {EditorState.t(), EditorState.buffer_registration_result()}
  defp register_buffer(%EditorState{} = state, buffer, context) do
    already_registered? = buffer in state.workspace.buffers.list

    next_state =
      MingaEditor.Handlers.BufferRegistry.add_buffer(state, buffer, context: context)

    result = if already_registered?, do: :already_registered, else: {:monitor, buffer}
    {next_state, result}
  end

  defp state_for_buffer(buf, opts \\ []) do
    buffers = %Buffers{
      active: buf,
      list: Keyword.get(opts, :list, [buf]),
      active_index: 0
    }

    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      shell_runtime: resolved_traditional_runtime(),
      workspace: %SessionState{
        viewport: Viewport.new(24, 80),
        editing: VimState.new(),
        buffers: buffers,
        windows: %Windows{
          tree: WindowTree.new(1),
          map: %{1 => Window.new(1, buf, 24, 80)},
          active: 1,
          next_id: 2
        }
      }
    }
  end

  defp resolved_traditional_runtime do
    Runtime.new(Registry.get(:traditional), %TraditionalState{})
  end

  defp with_buffer_pool(state, buffers) do
    then(state, fn state ->
      %{
        state
        | workspace:
            then(
              state.workspace,
              &MingaEditor.Session.State.set_buffers(
                &1,
                (fn %Buffers{} = current ->
                   %{current | list: buffers}
                 end).(state.workspace.buffers)
              )
            )
      }
    end)
  end

  defp active_window(state),
    do: Map.fetch!(state.workspace.windows.map, state.workspace.windows.active)

  defp state_with_inactive_tab_buffer(state, inactive_buf) do
    tab_a = Tab.new_file(1, "a.ex")
    {tb, tab_b} = TabBar.insert(TabBar.new(tab_a), :file, "b.ex")

    tab_b_context = %{
      buffers: %Buffers{active: inactive_buf, list: [inactive_buf], active_index: 0},
      editing: VimState.new(),
      viewport: Viewport.new(24, 80)
    }

    tb = TabBar.update_context(tb, tab_b.id, tab_b_context)

    state_with_tb =
      then(state, fn root ->
        shell_state =
          MingaEditor.Shell.Traditional.State.install_tab_bar(
            MingaEditor.Shell.Runtime.state(root.shell_runtime),
            tb
          )

        %{
          root
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
        }
      end)

    tb =
      TabBar.update_context(
        tb,
        1,
        MingaEditor.State.Tab.Context.snapshot(state_with_tb.workspace)
      )

    {then(state, fn root ->
       shell_state =
         MingaEditor.Shell.Traditional.State.install_tab_bar(
           MingaEditor.Shell.Runtime.state(root.shell_runtime),
           tb
         )

       %{
         root
         | shell_runtime:
             MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
       }
     end), tab_b}
  end
end
