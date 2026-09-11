defmodule MingaEditor.BufferFileIdentity do
  @moduledoc """
  Focused Editor workflow for logical buffer-to-file identity projection.

  `MingaEditor.State.TabBar` owns the identity-preserving tab and workspace
  transition. This module derives a project-aware file reference and installs
  the resulting Traditional shell value into the root.
  """

  alias Minga.Buffer
  alias Minga.Project.FileRef
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.TabBar

  @doc "Rebinds matching tab and workspace references after a buffer path changes."
  @spec rebind(EditorState.t(), pid(), String.t() | nil) :: EditorState.t()
  def rebind(%EditorState{} = state, buffer_pid, path)
      when is_pid(buffer_pid) and (is_binary(path) or is_nil(path)) do
    case traditional_tab_bar(state.shell_runtime) do
      %TabBar{} = tab_bar ->
        file_ref = file_ref(buffer_pid, path, state.workspace)
        install_tab_bar(state, TabBar.rebind_buffer_file(tab_bar, buffer_pid, file_ref))

      nil ->
        state
    end
  end

  @doc "Returns every live buffer pid represented by the workspace or tab snapshots."
  @spec known_open_pids(EditorState.t()) :: [pid()]
  def known_open_pids(%EditorState{} = state) do
    tab_pids =
      case traditional_tab_bar(state.shell_runtime) do
        %TabBar{} = tab_bar -> TabBar.buffer_pids(tab_bar)
        nil -> []
      end

    (state.workspace.buffers.list ++ tab_pids)
    |> Enum.filter(&is_pid/1)
    |> Enum.uniq()
  end

  @doc "Returns the project-aware file reference and display name for an active buffer."
  @spec resolve(EditorState.t(), pid()) :: {:ok, FileRef.t(), String.t()}
  def resolve(%EditorState{} = state, buffer_pid) when is_pid(buffer_pid) do
    case Buffer.file_path(buffer_pid) do
      path when is_binary(path) ->
        root = project_root(state.workspace)

        case FileRef.from_path(root, path) do
          {:ok, file_ref} ->
            {:ok, file_ref, file_ref.display_name}

          {:error, :outside_project} ->
            {:ok, FileRef.from_buffer(buffer_pid), Path.basename(path)}
        end

      _missing_path ->
        file_ref = FileRef.from_buffer(buffer_pid)
        {:ok, file_ref, file_ref.display_name}
    end
  end

  @spec file_ref(pid(), String.t() | nil, SessionState.t()) :: FileRef.t()
  defp file_ref(buffer_pid, path, %SessionState{} = workspace) do
    case {path, workspace.file_tree.project_root} do
      {path, root} when is_binary(path) and is_binary(root) ->
        case FileRef.from_path(root, path) do
          {:ok, file_ref} -> file_ref
          {:error, :outside_project} -> FileRef.from_buffer(buffer_pid)
        end

      _missing_path_or_root ->
        FileRef.from_buffer(buffer_pid)
    end
  end

  @spec project_root(SessionState.t()) :: String.t()
  defp project_root(%SessionState{} = workspace) do
    workspace.file_tree.project_root || workspace.file_tree.original_root || File.cwd!()
  end

  @spec traditional_tab_bar(Runtime.t()) :: TabBar.t() | nil
  defp traditional_tab_bar(%Runtime{state: %TraditionalState{} = shell_state}) do
    TraditionalState.tab_bar(shell_state)
  end

  defp traditional_tab_bar(%Runtime{}), do: nil

  @spec install_tab_bar(EditorState.t(), TabBar.t()) :: EditorState.t()
  defp install_tab_bar(%EditorState{} = state, %TabBar{} = tab_bar) do
    MingaEditor.WorkspaceWorkflow.install_tab_bar(state, tab_bar)
  end
end
