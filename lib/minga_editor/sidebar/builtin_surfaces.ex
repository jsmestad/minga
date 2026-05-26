defmodule MingaEditor.Sidebar.BuiltinSurfaces do
  @moduledoc """
  Registers built-in editor features as sidebar surfaces.

  The feature modules still own their domain state and content payloads. This module projects that state into the shared `MingaEditor.Extension.Sidebar` registry so GUI and TUI chrome have one source of truth for sidebar identity, visibility, focus, width, and action routing.
  """

  alias MingaEditor.Commands
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.GitStatus.Panel, as: GitStatusPanel
  alias MingaEditor.Layout
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState

  @builtin_source :builtin
  @git_status_id "git_status"
  @observatory_id "observatory"

  @doc "Registers built-in sidebar surfaces that do not have their own feature adapter."
  @spec register_contributions(Sidebar.table()) :: :ok | {:error, term()}
  def register_contributions(sidebar_registry \\ Sidebar.default_table()) do
    case sync_git_status_panel(nil, sidebar_registry) do
      :ok -> sync_observatory(false, sidebar_registry)
      {:error, _reason} = error -> error
    end
  end

  @doc "Synchronizes Git Status sidebar surface metadata from shell panel state."
  @spec sync_git_status_panel(GitStatusPanel.t() | map() | nil, Sidebar.table()) ::
          :ok | {:error, term()}
  def sync_git_status_panel(panel, sidebar_registry \\ Sidebar.default_table())

  def sync_git_status_panel(nil, sidebar_registry),
    do: register_git_status(false, 0, sidebar_registry)

  def sync_git_status_panel(%GitStatusPanel{} = panel, sidebar_registry) do
    register_git_status(true, length(panel.entries), sidebar_registry)
  end

  def sync_git_status_panel(%{} = panel, sidebar_registry) do
    panel |> GitStatusPanel.new() |> sync_git_status_panel(sidebar_registry)
  end

  @doc "Synchronizes BEAM Observatory sidebar surface metadata from shell visibility state."
  @spec sync_observatory(boolean(), Sidebar.table()) :: :ok | {:error, term()}
  def sync_observatory(visible?, sidebar_registry \\ Sidebar.default_table())
      when is_boolean(visible?) do
    result =
      Sidebar.register(sidebar_registry, @builtin_source, %{
        id: @observatory_id,
        display_name: "BEAM Observatory",
        description: "Runtime process tree",
        placement: :left,
        priority: 30,
        preferred_width: 30,
        visible?: visible?,
        focused?: visible?,
        semantic_kind: "observatory",
        icon: "network",
        action_handler: {__MODULE__, :handle_observatory_action}
      })

    focus_if_visible(result, visible?, @observatory_id, sidebar_registry)
  end

  @doc "Handles native sidebar actions for the Git Status surface."
  @spec handle_git_status_action(EditorState.t(), String.t(), map()) :: EditorState.t()
  def handle_git_status_action(%EditorState{} = state, "toggle", _context) do
    execute_git_porcelain_command(state, :git_status_toggle)
  end

  def handle_git_status_action(%EditorState{} = state, "activate", _context) do
    if EditorState.git_status_panel(state) do
      focus_git_status(state)
    else
      execute_git_porcelain_command(state, :git_status_toggle)
    end
  end

  def handle_git_status_action(%EditorState{} = state, _action, _context), do: state

  @doc "Handles native sidebar actions for the BEAM Observatory surface."
  @spec handle_observatory_action(EditorState.t(), String.t(), map()) :: EditorState.t()
  def handle_observatory_action(%EditorState{} = state, "toggle", _context) do
    state
    |> Commands.execute(:toggle_beam_observatory)
    |> normalize_command_result()
  end

  def handle_observatory_action(%EditorState{} = state, "activate", _context) do
    if EditorState.observatory_visible?(state) do
      focus_observatory(state)
    else
      state
      |> Commands.execute(:toggle_beam_observatory)
      |> normalize_command_result()
    end
  end

  def handle_observatory_action(%EditorState{} = state, _action, _context), do: state

  @spec register_git_status(boolean(), non_neg_integer(), Sidebar.table()) ::
          :ok | {:error, term()}
  defp register_git_status(visible?, badge_count, sidebar_registry) do
    result =
      Sidebar.register(sidebar_registry, @builtin_source, %{
        id: @git_status_id,
        display_name: "Git Status",
        description: "Repository changes",
        placement: :left,
        priority: 20,
        preferred_width: 30,
        visible?: visible?,
        focused?: visible?,
        semantic_kind: "git_status",
        icon: "point.3.filled.connected.trianglepath.dotted",
        badge_count: badge_count,
        action_handler: {__MODULE__, :handle_git_status_action}
      })

    focus_if_visible(result, visible?, @git_status_id, sidebar_registry)
  end

  @spec focus_if_visible(:ok | {:error, term()}, boolean(), String.t(), Sidebar.table()) ::
          :ok | {:error, term()}
  defp focus_if_visible(:ok, true, id, sidebar_registry),
    do: Sidebar.focus_left(sidebar_registry, id)

  defp focus_if_visible(:ok, false, _id, _sidebar_registry), do: :ok
  defp focus_if_visible({:error, _reason} = error, _visible?, _id, _sidebar_registry), do: error

  @spec focus_git_status(EditorState.t()) :: EditorState.t()
  defp focus_git_status(state) do
    :ok = Sidebar.focus_left(EditorState.sidebar_registry(state), @git_status_id)

    state
    |> EditorState.set_keymap_scope(:git_status)
    |> EditorState.set_sidebar_active_id(@git_status_id)
    |> Layout.invalidate()
    |> EditorState.invalidate_all_windows()
  end

  @spec focus_observatory(EditorState.t()) :: EditorState.t()
  defp focus_observatory(state) do
    :ok = Sidebar.focus_left(EditorState.sidebar_registry(state), @observatory_id)

    state
    |> EditorState.update_file_tree(&FileTreeState.unfocus/1)
    |> EditorState.set_keymap_scope(:editor)
    |> EditorState.set_sidebar_active_id(@observatory_id)
    |> Layout.invalidate()
    |> EditorState.invalidate_all_windows()
  end

  @spec normalize_command_result(EditorState.t() | {EditorState.t(), term()}) :: EditorState.t()
  defp normalize_command_result({state, _effect}), do: state
  defp normalize_command_result(state), do: state

  @spec execute_git_porcelain_command(EditorState.t(), atom()) :: EditorState.t()
  defp execute_git_porcelain_command(state, command) do
    module = :"Elixir.MingaGitPorcelain.Commands"

    if git_porcelain_running?() and Code.ensure_loaded?(module) do
      :erlang.apply(module, :execute, [state, command])
    else
      git_porcelain_unavailable(state)
    end
  end

  @spec git_porcelain_unavailable(EditorState.t()) :: EditorState.t()
  defp git_porcelain_unavailable(state) do
    message = "Git porcelain extension is disabled or failed to load"
    Minga.Log.warning(:editor, message)
    EditorState.set_status(state, message)
  end

  @spec git_porcelain_running?() :: boolean()
  defp git_porcelain_running? do
    case Process.whereis(Minga.Extension.Registry) do
      nil -> false
      _pid -> git_porcelain_running_in_registry?()
    end
  catch
    :exit, _reason -> false
  end

  @spec git_porcelain_running_in_registry?() :: boolean()
  defp git_porcelain_running_in_registry? do
    case Minga.Extension.Registry.get(:minga_git_porcelain) do
      {:ok, %{status: :running}} -> true
      _ -> false
    end
  end
end
