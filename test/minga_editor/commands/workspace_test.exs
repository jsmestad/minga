defmodule MingaEditor.Commands.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Command
  alias Minga.Project.FileRef
  alias MingaAgent.ProjectView
  alias MingaAgent.Providers.RecordingProvider
  alias MingaAgent.Session
  alias MingaEditor.Commands.Workspace
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.WorkspaceIconSource
  alias MingaEditor.UI.Picker.WorkspaceSource
  alias MingaEditor.UI.Prompt.WorkspaceRename
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.Workspace, as: WorkspaceModel
  alias MingaEditor.State.WorkspaceReview
  alias MingaEditor.Workspace.State, as: WorkspaceState

  @moduletag :tmp_dir

  # Builds an EditorState with a manual workspace file tab and two agent workspaces.
  # The manual tab is id 1 / workspace 0; agent tabs are ids 2 and 3 / workspaces 1 and 2.
  defp make_state do
    {:ok, buf} = start_supervised({BufferProcess, content: "hello"})

    window = Window.new(1, buf, 24, 80)

    file_tab = Tab.new_file(1, "file.ex")
    agent_tab_1 = %{Tab.new_agent(2, "Agent 1") | group_id: 1}
    agent_tab_2 = %{Tab.new_agent(3, "Agent 2") | group_id: 2}

    tb = %{
      TabBar.new(file_tab)
      | tabs: [file_tab, agent_tab_1, agent_tab_2],
        active_id: 1,
        next_id: 4
    }

    {tb, _} = TabBar.add_workspace(tb, "Agent 1")

    {tb, _} = TabBar.add_workspace(tb, "Agent 2")

    %EditorState{
      port_manager: self(),
      workspace: %WorkspaceState{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{active: buf, list: [buf]},
        windows: %Windows{
          tree: {:leaf, 1},
          map: %{1 => window},
          active: 1,
          next_id: 2
        }
      },
      shell_state: %TraditionalState{tab_bar: tb}
    }
  end

  defp manual_workspace_state(buffer, mode) do
    %WorkspaceState{
      viewport: Viewport.new(24, 80),
      keymap_scope: :editor,
      buffers: %Buffers{active: buffer, list: [buffer], active_index: 0},
      windows: %Windows{
        tree: WindowTree.new(1),
        map: %{1 => Window.new(1, buffer, 24, 80)},
        active: 1,
        next_id: 2
      },
      editing: VimState.transition(VimState.new(), mode)
    }
  end

  defp agent_workspace_state(buffer, mode) do
    %WorkspaceState{
      viewport: Viewport.new(24, 80),
      keymap_scope: :agent,
      buffers: %Buffers{active: buffer, list: [buffer], active_index: 0},
      windows: %Windows{
        tree: WindowTree.new(1),
        map: %{1 => Window.new_agent_chat(1, buffer, 24, 80)},
        active: 1,
        next_id: 2
      },
      editing: VimState.transition(VimState.new(), mode)
    }
  end

  defp put_active_workspace_project_view(state, project_view) do
    put_workspace_project_view(
      state,
      TabBar.active_workspace_id(state.shell_state.tab_bar),
      project_view
    )
  end

  defp put_workspace_project_view(state, workspace_id, project_view) do
    tb = state.shell_state.tab_bar

    EditorState.set_tab_bar(
      state,
      TabBar.update_workspace(
        tb,
        workspace_id,
        &WorkspaceModel.set_project_view(&1, project_view)
      )
    )
  end

  defp put_active_workspace_review(state, review) do
    put_workspace_review(state, TabBar.active_workspace_id(state.shell_state.tab_bar), review)
  end

  defp put_workspace_review(state, workspace_id, review) do
    tb = state.shell_state.tab_bar

    EditorState.set_tab_bar(
      state,
      TabBar.update_workspace(tb, workspace_id, &WorkspaceModel.set_review(&1, review))
    )
  end

  defp put_workspace_session(state, session, workspace_id \\ 1) do
    tb = state.shell_state.tab_bar

    EditorState.set_tab_bar(
      state,
      TabBar.update_workspace(tb, workspace_id, &WorkspaceModel.set_session(&1, session))
    )
  end

  defp put_file_tab_in_workspace(state, workspace_id) do
    tb = state.shell_state.tab_bar
    tb = TabBar.move_tab_to_workspace(tb, 1, workspace_id)
    EditorState.set_tab_bar(state, tb)
  end

  defp start_recording_session do
    session =
      start_supervised!({Session, provider: RecordingProvider, provider_opts: [test_pid: self()]})

    :sys.get_state(session)
    session
  end

  defp file_ref do
    {:ok, ref} = Minga.Project.FileRef.from_path("/tmp/minga", "lib/a.ex")
    ref
  end

  defp make_workspace_switch_state do
    manual_saved_buf =
      start_supervised!(
        Supervisor.child_spec({BufferProcess, [content: "manual saved"]},
          id: {:buffer_process, :manual_saved}
        )
      )

    manual_live_buf =
      start_supervised!(
        Supervisor.child_spec({BufferProcess, [content: "manual live"]},
          id: {:buffer_process, :manual_live}
        )
      )

    agent_buf =
      start_supervised!(
        Supervisor.child_spec({BufferProcess, [content: "agent"]},
          id: {:buffer_process, :agent}
        )
      )

    manual_saved_ctx =
      manual_saved_buf
      |> manual_workspace_state(:normal)
      |> TabContext.from_workspace()

    agent_ctx =
      agent_buf
      |> agent_workspace_state(:normal)
      |> TabContext.from_workspace()

    manual_tab = Tab.new_file(1, "manual.ex") |> Tab.set_context(manual_saved_ctx)

    {tb, agent_workspace} = TabBar.add_workspace(TabBar.new(manual_tab), "Agent")

    agent_tab =
      Tab.new_agent(2, "Agent") |> Tab.set_group(agent_workspace.id) |> Tab.set_context(agent_ctx)

    tb = %{tb | tabs: [manual_tab, agent_tab], active_id: 1, next_id: 3}

    state = %EditorState{
      port_manager: self(),
      workspace: manual_workspace_state(manual_live_buf, :insert),
      shell_state: %TraditionalState{tab_bar: tb}
    }

    {state, manual_live_buf, agent_buf}
  end

  describe "__commands__/0" do
    test "exports the workspace command contract" do
      commands = Workspace.__commands__()

      assert Enum.all?(commands, &match?(%Command{}, &1))

      for name <- [
            :workspace_next,
            :workspace_prev,
            :manual_workspace,
            :workspace_toggle,
            :workspace_close,
            :workspace_close_keep,
            :workspace_review_drafts,
            :workspace_promote,
            :workspace_discard,
            :workspace_resolve_conflicts,
            :workspace_discard_and_close,
            :workspace_list,
            :workspace_rename,
            :workspace_set_icon,
            :workspace_next_agent
          ] do
        assert Enum.any?(commands, &(&1.name == name))
      end

      for n <- 1..9 do
        assert Enum.any?(commands, &(&1.name == String.to_atom("workspace_goto_#{n}")))
      end

      assert %{description: "Next workspace", requires_buffer: false} =
               Enum.find(commands, &(&1.name == :workspace_next))

      assert %{description: "Workspace 1", requires_buffer: false} =
               Enum.find(commands, &(&1.name == :workspace_goto_1))
    end
  end

  describe "workspace_next/1" do
    test "switches to the next workspace's first tab" do
      state = make_state()
      result = Workspace.workspace_next(state)

      assert %EditorState{} = result
      assert result.shell_state.tab_bar.active_id == 2
    end
  end

  describe "workspace_prev/1" do
    test "switches to the previous workspace's first tab" do
      state = make_state()
      result = Workspace.workspace_prev(state)

      assert %EditorState{} = result
      assert result.shell_state.tab_bar.active_id == 3
    end
  end

  describe "workspace_toggle/1" do
    test "restores the incoming workspace context and snapshots the tab left behind" do
      {state, manual_live_buf, agent_buf} = make_workspace_switch_state()
      result = Workspace.workspace_toggle(state)

      assert %EditorState{} = result
      assert result.shell_state.tab_bar.active_id == 2
      assert result.workspace.buffers.active == agent_buf
      assert result.workspace.editing.mode == :normal

      manual_tab = TabBar.get(result.shell_state.tab_bar, 1)
      assert manual_tab.context.buffers.active == manual_live_buf
      assert manual_tab.context.editing.mode == :insert
    end
  end

  describe "workspace_close/1" do
    test "migrates the active agent workspace tabs back to manual" do
      state = make_state() |> Workspace.workspace_next()
      result = Workspace.workspace_close(state)

      assert %EditorState{} = result
      tab_bar = result.shell_state.tab_bar
      assert TabBar.active_workspace_id(tab_bar) == 0
      assert TabBar.get_workspace(tab_bar, 1) == nil
      assert Enum.map(TabBar.tabs_in_workspace(tab_bar, 0), & &1.id) == [1, 2]
      assert Enum.map(TabBar.tabs_in_workspace(tab_bar, 2), & &1.id) == [3]
    end

    test "leaving the manual workspace alone is a no-op" do
      state = make_state()
      assert Workspace.workspace_close(state) == state
    end

    test "clears the provider and discards the overlay when closing a clean workspace with a file tab active",
         %{
           tmp_dir: dir
         } do
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, "lib/a.ex"), "base")
      {:ok, project_view} = ProjectView.overlay(dir)
      changeset = project_view.ref.changeset
      ref = Process.monitor(changeset)
      overlay_path = ProjectView.working_dir(project_view)
      session = start_recording_session()

      state =
        make_state()
        |> put_file_tab_in_workspace(1)
        |> put_workspace_session(session)
        |> put_workspace_project_view(1, project_view)

      result = Workspace.workspace_close(state)

      assert_receive {:provider_refresh, nil}
      assert_receive {:DOWN, ^ref, :process, ^changeset, :normal}
      refute File.dir?(overlay_path)
      assert TabBar.get_workspace(result.shell_state.tab_bar, 1) == nil
      assert TabBar.active_workspace_id(result.shell_state.tab_bar) == 0
    end

    test "clears a dead ProjectView when reviewing drafts", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, "lib/a.ex"), "base")
      {:ok, project_view} = ProjectView.overlay(dir)
      changeset = project_view.ref.changeset
      overlay_path = ProjectView.working_dir(project_view)
      ref = Process.monitor(changeset)

      Process.exit(changeset, :kill)
      assert_receive {:DOWN, ^ref, :process, ^changeset, _reason}

      state =
        make_state()
        |> Workspace.workspace_next()
        |> put_active_workspace_project_view(project_view)
        |> put_active_workspace_review(%WorkspaceReview{
          state: :needs_review,
          changed_files: [file_ref()]
        })

      result = Workspace.workspace_review_drafts(state)
      workspace = TabBar.get_workspace(result.shell_state.tab_bar, 1)

      assert workspace.project_view == nil
      assert workspace.review.state == :clean
      File.rm_rf!(overlay_path)
    end

    test "clears a dead ProjectView when promoting drafts", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, "lib/a.ex"), "base")
      {:ok, project_view} = ProjectView.overlay(dir)
      changeset = project_view.ref.changeset
      overlay_path = ProjectView.working_dir(project_view)
      ref = Process.monitor(changeset)

      Process.exit(changeset, :kill)
      assert_receive {:DOWN, ^ref, :process, ^changeset, _reason}

      state =
        make_state()
        |> Workspace.workspace_next()
        |> put_active_workspace_project_view(project_view)
        |> put_active_workspace_review(%WorkspaceReview{
          state: :needs_review,
          changed_files: [file_ref()]
        })

      result = Workspace.workspace_promote(state)
      workspace = TabBar.get_workspace(result.shell_state.tab_bar, 1)

      assert workspace.project_view == nil
      assert workspace.review.state == :clean
      File.rm_rf!(overlay_path)
    end

    test "clears a dead ProjectView when discarding drafts", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, "lib/a.ex"), "base")
      {:ok, project_view} = ProjectView.overlay(dir)
      changeset = project_view.ref.changeset
      overlay_path = ProjectView.working_dir(project_view)
      ref = Process.monitor(changeset)

      Process.exit(changeset, :kill)
      assert_receive {:DOWN, ^ref, :process, ^changeset, _reason}

      state =
        make_state()
        |> Workspace.workspace_next()
        |> put_active_workspace_project_view(project_view)
        |> put_active_workspace_review(%WorkspaceReview{
          state: :needs_review,
          changed_files: [file_ref()]
        })

      result = Workspace.workspace_discard(state)
      workspace = TabBar.get_workspace(result.shell_state.tab_bar, 1)

      assert workspace.project_view == nil
      assert workspace.review.state == :clean
      File.rm_rf!(overlay_path)
    end

    test "discard and close keeps the workspace open when the ProjectView is dead", %{
      tmp_dir: dir
    } do
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, "lib/a.ex"), "base")
      {:ok, project_view} = ProjectView.overlay(dir)
      changeset = project_view.ref.changeset
      overlay_path = ProjectView.working_dir(project_view)
      ref = Process.monitor(changeset)

      Process.exit(changeset, :kill)
      assert_receive {:DOWN, ^ref, :process, ^changeset, _reason}

      state =
        make_state()
        |> Workspace.workspace_next()
        |> put_active_workspace_project_view(project_view)
        |> put_active_workspace_review(%WorkspaceReview{
          state: :needs_review,
          changed_files: [file_ref()]
        })

      result = Workspace.workspace_discard_and_close(state)
      workspace = TabBar.get_workspace(result.shell_state.tab_bar, 1)

      assert workspace != nil
      assert workspace.project_view == nil
      assert workspace.review.state == :clean
      File.rm_rf!(overlay_path)
    end

    test "requires confirmation when active workspace has drafts" do
      {:ok, changed_ref} = FileRef.from_path("/tmp/minga", "lib/a.ex")

      state =
        make_state()
        |> Workspace.workspace_next()
        |> put_active_workspace_review(%WorkspaceReview{
          state: :needs_review,
          changed_files: [changed_ref]
        })

      result = Workspace.workspace_close(state)

      assert result.shell_state.tab_bar == state.shell_state.tab_bar

      assert EditorState.status_msg(result) =~
               "Actions: Keep workspace, Review drafts, Discard drafts and close"

      assert EditorState.status_msg(result) =~ "Dirty buffers are separate"
    end

    test "prompts to review when ProjectView diffs exist but cached review is clean", %{
      tmp_dir: dir
    } do
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, "lib/a.ex"), "base")
      {:ok, project_view} = ProjectView.overlay(dir)
      File.write!(Path.join(ProjectView.working_dir(project_view), "lib/a.ex"), "shell draft")

      state =
        make_state()
        |> put_file_tab_in_workspace(1)
        |> put_workspace_project_view(1, project_view)
        |> put_workspace_review(1, %WorkspaceReview{state: :clean})

      result = Workspace.workspace_close(state)

      assert TabBar.get_workspace(result.shell_state.tab_bar, 1) != nil
      assert TabBar.active_workspace_id(result.shell_state.tab_bar) == 1

      assert EditorState.status_msg(result) =~
               "Actions: Keep workspace, Review drafts, Discard drafts and close"

      assert EditorState.status_msg(result) =~ "Workspace has 1 draft file(s)"
    end

    test "discard and close removes a workspace with drafts" do
      state =
        make_state()
        |> Workspace.workspace_next()
        |> put_active_workspace_review(%WorkspaceReview{
          state: :needs_review,
          changed_files: [file_ref()]
        })

      result = Workspace.workspace_discard_and_close(state)

      assert TabBar.get_workspace(result.shell_state.tab_bar, 1) == nil
      assert TabBar.active_workspace_id(result.shell_state.tab_bar) == 0
    end

    test "resolve conflicts keeps workspace conflicted when promote still conflicts", %{
      tmp_dir: dir
    } do
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, "lib/a.ex"), "base")
      {:ok, project_view} = ProjectView.overlay(dir)
      :ok = ProjectView.write_file(project_view, "lib/a.ex", "draft")
      File.write!(Path.join(dir, "lib/a.ex"), "current file")

      state =
        make_state()
        |> Workspace.workspace_next()
        |> put_active_workspace_project_view(project_view)
        |> put_active_workspace_review(%WorkspaceReview{
          state: :conflict,
          changed_files: [file_ref()],
          conflict_files: [file_ref()]
        })

      result = Workspace.workspace_resolve_conflicts(state)
      review = TabBar.get_workspace(result.shell_state.tab_bar, 1).review

      assert review.state == :conflict
      assert review.conflict_files != []
    end
  end

  describe "workspace_review_drafts/1" do
    test "populates needs_review from ProjectView.diff when cached review is clean", %{
      tmp_dir: dir
    } do
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, "lib/a.ex"), "base")
      {:ok, project_view} = ProjectView.overlay(dir)
      :ok = ProjectView.write_file(project_view, "lib/a.ex", "draft")
      {:ok, changed_ref} = FileRef.from_path(dir, "lib/a.ex")

      state =
        make_state()
        |> Workspace.workspace_next()
        |> put_active_workspace_project_view(project_view)

      result = Workspace.workspace_review_drafts(state)
      review = TabBar.get_workspace(result.shell_state.tab_bar, 1).review

      assert review.state == :needs_review
      assert review.changed_files == [changed_ref]
    end
  end

  describe "workspace_promote/1" do
    test "promotes clean ProjectView drafts and refreshes the workspace to clean", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, "lib/a.ex"), "base")
      {:ok, project_view} = ProjectView.overlay(dir)
      :ok = ProjectView.write_file(project_view, "lib/a.ex", "draft")
      session = start_recording_session()

      state =
        make_state()
        |> put_file_tab_in_workspace(1)
        |> put_workspace_session(session)
        |> put_workspace_project_view(1, project_view)
        |> put_workspace_review(1, %WorkspaceReview{
          state: :needs_review,
          changed_files: [file_ref()]
        })

      result = Workspace.workspace_promote(state)
      workspace = TabBar.get_workspace(result.shell_state.tab_bar, 1)

      assert_receive {:provider_refresh, refreshed_view}
      assert workspace.review.state == :clean
      assert {:ok, []} = ProjectView.diff(workspace.project_view)
      assert {:ok, []} = ProjectView.diff(refreshed_view)
    end

    test "refreshes a clean ProjectView without leaving a stale ref", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, "lib/a.ex"), "base")
      {:ok, project_view} = ProjectView.overlay(dir)
      session = start_recording_session()

      state =
        make_state()
        |> put_file_tab_in_workspace(1)
        |> put_workspace_session(session)
        |> put_workspace_project_view(1, project_view)
        |> put_workspace_review(1, %WorkspaceReview{state: :clean})

      result = Workspace.workspace_promote(state)
      workspace = TabBar.get_workspace(result.shell_state.tab_bar, 1)

      assert_receive {:provider_refresh, refreshed_view}
      assert workspace.review.state == :clean
      assert workspace.project_view != nil
      assert ProjectView.active?(workspace.project_view)
      refute ProjectView.active?(project_view)
      assert {:ok, []} = ProjectView.diff(workspace.project_view)
      assert {:ok, []} = ProjectView.diff(refreshed_view)
    end
  end

  describe "workspace_discard/1" do
    test "clears drafts and keeps the workspace open", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, "lib/a.ex"), "base")
      {:ok, project_view} = ProjectView.overlay(dir)
      :ok = ProjectView.write_file(project_view, "lib/a.ex", "draft")
      session = start_recording_session()

      state =
        make_state()
        |> put_file_tab_in_workspace(1)
        |> put_workspace_session(session)
        |> put_workspace_project_view(1, project_view)
        |> put_workspace_review(1, %WorkspaceReview{
          state: :needs_review,
          changed_files: [file_ref()]
        })

      result = Workspace.workspace_discard(state)
      workspace = TabBar.get_workspace(result.shell_state.tab_bar, 1)

      assert_receive {:provider_refresh, refreshed_view}
      assert workspace != nil
      assert workspace.review.state == :clean
      assert {:ok, []} = ProjectView.diff(workspace.project_view)
      assert {:ok, []} = ProjectView.diff(refreshed_view)
    end

    test "refreshes a clean ProjectView without leaving a stale ref", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, "lib/a.ex"), "base")
      {:ok, project_view} = ProjectView.overlay(dir)
      session = start_recording_session()

      state =
        make_state()
        |> put_file_tab_in_workspace(1)
        |> put_workspace_session(session)
        |> put_workspace_project_view(1, project_view)
        |> put_workspace_review(1, %WorkspaceReview{state: :clean})

      result = Workspace.workspace_discard(state)
      workspace = TabBar.get_workspace(result.shell_state.tab_bar, 1)

      assert_receive {:provider_refresh, refreshed_view}
      assert workspace.review.state == :clean
      assert workspace.project_view != nil
      assert ProjectView.active?(workspace.project_view)
      refute ProjectView.active?(project_view)
      assert {:ok, []} = ProjectView.diff(workspace.project_view)
      assert {:ok, []} = ProjectView.diff(refreshed_view)
    end
  end

  describe "workspace_resolve_conflicts/1" do
    test "promotes a resolved conflict back to clean", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, "lib/a.ex"), "base")
      {:ok, project_view} = ProjectView.overlay(dir)
      :ok = ProjectView.write_file(project_view, "lib/a.ex", "draft")
      {:ok, changed_ref} = FileRef.from_path(dir, "lib/a.ex")

      state =
        make_state()
        |> Workspace.workspace_next()
        |> put_active_workspace_project_view(project_view)
        |> put_active_workspace_review(%WorkspaceReview{
          state: :conflict,
          changed_files: [changed_ref],
          conflict_files: [changed_ref]
        })

      result = Workspace.workspace_resolve_conflicts(state)
      workspace = TabBar.get_workspace(result.shell_state.tab_bar, 1)

      assert workspace.review.state == :clean
      assert {:ok, []} = ProjectView.diff(workspace.project_view)
    end
  end

  describe "workspace_list/1" do
    test "opens the picker with the active workspace selected" do
      state = make_state() |> Workspace.workspace_next()
      result = Workspace.workspace_list(state)

      assert {:picker,
              %{picker_ui: %{source: WorkspaceSource, picker: %{title: "Switch Workspace"}}}} =
               result.shell_state.modal

      active_item =
        result
        |> Context.from_editor_state()
        |> WorkspaceSource.candidates()
        |> Enum.find(&(&1.id == 1))

      assert active_item.label =~ "Agent 1"
      assert String.ends_with?(active_item.label, " •")
    end
  end

  describe "workspace_set_icon/1" do
    test "opens the icon picker for the active workspace" do
      state = make_state() |> Workspace.workspace_next()
      result = Workspace.workspace_set_icon(state)

      assert {:picker,
              %{picker_ui: %{source: WorkspaceIconSource, picker: %{title: "Set Workspace Icon"}}}} =
               result.shell_state.modal

      current_icon =
        result
        |> Context.from_editor_state()
        |> WorkspaceIconSource.candidates()
        |> Enum.find(&(&1.label == "cpu •"))

      assert current_icon != nil
    end
  end

  describe "workspace_rename/1" do
    test "opens the prompt with the active workspace label prefilled" do
      state = make_state() |> Workspace.workspace_next()
      result = Workspace.workspace_rename(state)

      assert {:prompt,
              %{
                prompt_ui: %{
                  handler: WorkspaceRename,
                  label: "Rename workspace: ",
                  text: "Agent 1",
                  cursor: 7
                }
              }} =
               result.shell_state.modal
    end
  end

  describe "switch_to_manual_workspace/1" do
    test "switches to the first manual workspace tab" do
      state = make_state() |> Workspace.workspace_next()
      result = Workspace.switch_to_manual_workspace(state)

      assert %EditorState{} = result
      assert result.shell_state.tab_bar.active_id == 1
    end
  end

  describe "workspace_goto/2" do
    test "workspace 0 switches to manual workspace tabs" do
      state = make_state() |> Workspace.workspace_next()
      result = Workspace.workspace_goto(state, 0)

      assert %EditorState{} = result
      assert result.shell_state.tab_bar.active_id == 1
    end

    test "workspace numbers are one-based" do
      state = make_state()

      assert Workspace.workspace_goto(state, 1).shell_state.tab_bar.active_id == 2
      assert Workspace.workspace_goto(state, 2).shell_state.tab_bar.active_id == 3
    end
  end
end
