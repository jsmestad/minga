defmodule MingaEditor.Shell.Traditional.OnBufferAddedTest do
  @moduledoc """
  Focused tests for the Traditional shell's pure buffer-added calculation.

  Buffer identity is prepared by the workflow before the shell wires its tab
  and file-ref state.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Project.FileRef
  alias MingaEditor.Shell.BufferMetadata
  alias MingaEditor.Shell.Traditional
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.Viewport
  alias MingaEditor.Session.State, as: SessionState

  defp blank_workspace do
    %SessionState{viewport: Viewport.new(24, 80)}
  end

  defp elem_insert(%TabBar{} = tab_bar, kind, label) do
    {tab_bar, _tab} = TabBar.insert(tab_bar, kind, label)
    tab_bar
  end

  describe "GUI tab actions" do
    test "closing an inactive tab returns the two-tuple shell action contract" do
      workspace = blank_workspace()

      tab_bar =
        TabBar.new(Tab.new_file(1, "one"), nil)
        |> elem_insert(:file, "two")
        |> TabBar.update_context(2, SessionState.to_tab_context(workspace))

      shell_state = %ShellState{tab_bar: tab_bar}

      assert {%ShellState{}, %SessionState{}} =
               Traditional.handle_gui_action(shell_state, workspace, {:close_tab, 2})
    end
  end

  describe "file refs" do
    test "populates file refs when opening file tabs" do
      root = Path.join(System.tmp_dir!(), "minga-on-buffer-added")
      path = Path.join([root, "lib", "user.ex"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "hello")
      buf = start_supervised!({BufferProcess, file_path: path})

      workspace = workspace_for(buf, root)
      shell_state = %ShellState{tab_bar: TabBar.new(Tab.new_file(1, "initial.ex"), root)}
      assert {:ok, expected_ref} = FileRef.from_path(root, path)
      metadata = BufferMetadata.new(buf, :open, "user.ex", path, expected_ref)

      {new_shell, _workspace} = Traditional.on_buffer_added(shell_state, workspace, metadata)

      active_tab = TabBar.active(new_shell.tab_bar)
      assert active_tab.file_ref == expected_ref
      assert Workspace.has_file?(TabBar.get_workspace(new_shell.tab_bar, 0), expected_ref)
    end

    test "falls back to a buffer ref for unsaved scratch buffers" do
      root = Path.join(System.tmp_dir!(), "minga-on-buffer-added-scratch")
      buf = start_supervised!({BufferProcess, content: "scratch", buffer_name: "*scratch*"})
      expected_ref = FileRef.from_buffer(buf, "*scratch*")
      metadata = BufferMetadata.new(buf, :open, "*scratch*", nil, expected_ref)
      workspace = workspace_for(buf, root)
      shell_state = %ShellState{tab_bar: TabBar.new(Tab.new_file(1, "initial.ex"), root)}

      {new_shell, _workspace} = Traditional.on_buffer_added(shell_state, workspace, metadata)

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
      label = Path.basename(path)
      expected_ref = FileRef.from_buffer(buf, label)
      metadata = BufferMetadata.new(buf, :open, label, path, expected_ref)
      workspace = workspace_for(buf, root)
      shell_state = %ShellState{tab_bar: TabBar.new(Tab.new_file(1, "initial.ex"), root)}

      {new_shell, _workspace} = Traditional.on_buffer_added(shell_state, workspace, metadata)

      active_tab = TabBar.active(new_shell.tab_bar)
      workspace = TabBar.get_workspace(new_shell.tab_bar, 0)

      assert active_tab.file_ref == expected_ref
      assert workspace.active_file == expected_ref
      assert Workspace.has_file?(workspace, expected_ref)
    end
  end

  @spec workspace_for(pid(), String.t()) :: SessionState.t()
  defp workspace_for(buffer, root) do
    %SessionState{
      viewport: Viewport.new(24, 80),
      buffers: %Buffers{active: buffer, list: [buffer]}
    }
    |> SessionState.set_file_tree(%FileTreeState{project_root: root})
  end
end
