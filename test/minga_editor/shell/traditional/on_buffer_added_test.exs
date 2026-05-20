defmodule MingaEditor.Shell.Traditional.OnBufferAddedTest do
  @moduledoc """
  Focused tests for `Shell.Traditional.on_buffer_added/4`.

  Covers the dashboard auto-dismiss hook (#1425): when a buffer becomes
  active, any open dashboard modal is dismissed so the splash does not
  stick visually behind the buffer view.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Dashboard
  alias Minga.Project.FileRef
  alias MingaEditor.Shell.Traditional
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.ModalOverlay.Dashboard, as: DashboardPayload
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.Picker, as: PickerLegacy
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.UI.Picker, as: UIPicker
  alias MingaEditor.Viewport
  alias MingaEditor.Workspace.State, as: WorkspaceState

  defp blank_workspace do
    %WorkspaceState{viewport: Viewport.new(24, 80)}
  end

  describe "file refs" do
    test "populates file refs when opening file tabs" do
      root = Path.join(System.tmp_dir!(), "minga-on-buffer-added")
      path = Path.join([root, "lib", "user.ex"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "hello")
      buf = start_supervised!({BufferProcess, file_path: path})

      workspace = %WorkspaceState{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{active: buf, list: [buf]},
        file_tree: %FileTreeState{project_root: root}
      }

      shell_state = %ShellState{tab_bar: TabBar.new(Tab.new_file(1, "initial.ex"), root)}

      {new_shell, _workspace, _effects} =
        Traditional.on_buffer_added(shell_state, workspace, buf, :open)

      active_tab = TabBar.active(new_shell.tab_bar)
      assert {:ok, expected_ref} = FileRef.from_path(root, path)
      assert active_tab.file_ref == expected_ref
      assert Workspace.has_file?(TabBar.get_workspace(new_shell.tab_bar, 0), expected_ref)
    end

    test "falls back to a buffer ref for unsaved scratch buffers" do
      root = Path.join(System.tmp_dir!(), "minga-on-buffer-added-scratch")
      buf = start_supervised!({BufferProcess, content: "scratch", buffer_name: "*scratch*"})
      expected_ref = FileRef.from_buffer(buf)

      workspace = %WorkspaceState{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{active: buf, list: [buf]},
        file_tree: %FileTreeState{project_root: root}
      }

      shell_state = %ShellState{tab_bar: TabBar.new(Tab.new_file(1, "initial.ex"), root)}

      {new_shell, _workspace, _effects} =
        Traditional.on_buffer_added(shell_state, workspace, buf, :open)

      active_tab = TabBar.active(new_shell.tab_bar)
      workspace = TabBar.get_workspace(new_shell.tab_bar, 0)

      assert active_tab.file_ref == expected_ref
      assert workspace.active_file == expected_ref
      assert Workspace.has_file?(workspace, expected_ref)
    end

    test "falls back to a buffer ref for paths outside the project root" do
      root = Path.join(System.tmp_dir!(), "minga-on-buffer-added-outside-root")
      path = Path.join(System.tmp_dir!(), "minga-on-buffer-added-outside-root-file.ex")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "hello")
      buf = start_supervised!({BufferProcess, file_path: path})
      expected_ref = FileRef.from_buffer(buf)

      workspace = %WorkspaceState{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{active: buf, list: [buf]},
        file_tree: %FileTreeState{project_root: root}
      }

      shell_state = %ShellState{tab_bar: TabBar.new(Tab.new_file(1, "initial.ex"), root)}

      {new_shell, _workspace, _effects} =
        Traditional.on_buffer_added(shell_state, workspace, buf, :open)

      active_tab = TabBar.active(new_shell.tab_bar)
      workspace = TabBar.get_workspace(new_shell.tab_bar, 0)

      assert active_tab.file_ref == expected_ref
      assert workspace.active_file == expected_ref
      assert Workspace.has_file?(workspace, expected_ref)
    end
  end

  describe "dashboard auto-dismiss" do
    test "dismisses an active dashboard modal when a buffer is added" do
      shell_state = %ShellState{
        modal: {:dashboard, DashboardPayload.new(Dashboard.new_state())}
      }

      buf = start_supervised!({BufferProcess, content: "hello"})

      {new_shell, _ws, _effects} =
        Traditional.on_buffer_added(shell_state, blank_workspace(), buf, :open)

      assert new_shell.modal == :none
    end

    test "leaves an active picker modal alone when a buffer is added" do
      picker_payload =
        PickerPayload.new(%PickerLegacy{
          picker: UIPicker.new([], title: "test"),
          source: nil,
          restore: 0
        })

      shell_state = %ShellState{modal: {:picker, picker_payload}}

      buf = start_supervised!({BufferProcess, content: "hello"})

      {new_shell, _ws, _effects} =
        Traditional.on_buffer_added(shell_state, blank_workspace(), buf, :open)

      assert new_shell.modal == {:picker, picker_payload}
    end

    test "is a no-op when no modal is active" do
      shell_state = %ShellState{modal: :none}
      buf = start_supervised!({BufferProcess, content: "hello"})

      {new_shell, _ws, _effects} =
        Traditional.on_buffer_added(shell_state, blank_workspace(), buf, :open)

      assert new_shell.modal == :none
    end
  end
end
