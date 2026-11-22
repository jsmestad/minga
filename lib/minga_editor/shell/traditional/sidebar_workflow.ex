defmodule MingaEditor.Shell.Traditional.SidebarWorkflow do
  @moduledoc """
  Effect boundary for Traditional sidebar selection and built-in surfaces.

  Registry synchronization, logging, and timer cancellation stay here. The
  immutable sidebar and Observatory transitions remain in their value owners.
  """

  alias Minga.Extension.CodeLease
  alias Minga.Git
  alias Minga.Log
  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Commands.FileTree
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Extension.Sidebar.Entry
  alias MingaEditor.FileTree.Feature, as: FileTreeFeature
  alias MingaEditor.GitStatus.Panel, as: GitStatusPanel
  alias MingaEditor.GitStatus.TUIState
  alias MingaEditor.Layout
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.Observatory
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Sidebar.BuiltinSurfaces
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState

  @type state :: EditorState.t()
  @type commit_target :: {:ok, String.t(), String.t() | nil} | :not_git | :repo_unavailable
  @git_status_id Entry.git_status_id()

  @doc "Toggles the registered native Git Status sidebar."
  @spec toggle_git_status(state()) :: state()
  def toggle_git_status(%EditorState{} = state) do
    Sidebar.dispatch_action(Sidebar.table_for(state), state, @git_status_id, "toggle", %{})
  end

  @doc "Returns the commit target of the exact panel shown to the user."
  @spec prepare_git_commit(state()) :: {state(), commit_target()}
  def prepare_git_commit(
        %EditorState{shell_runtime: %Runtime{state: %TraditionalState{}}} = state
      ) do
    case Sidebar.get(Sidebar.table_for(state), @git_status_id) do
      %{source: {:extension, _name} = source} ->
        if git_status_available?(source),
          do: prepare_visible_git_commit(state),
          else: git_status_unavailable(state)

      _ ->
        git_status_unavailable(state)
    end
  end

  def prepare_git_commit(%EditorState{} = state), do: git_status_unavailable(state)

  @doc false
  @spec handle_git_status_action(state(), String.t(), Sidebar.source()) :: state()
  def handle_git_status_action(
        %EditorState{shell_runtime: %Runtime{state: %TraditionalState{}}} = state,
        action,
        source
      )
      when action in ["toggle", "activate"] do
    if git_status_available?(source) do
      apply_git_status_action(state, action, git_status_panel(state), source)
    else
      state
    end
  end

  def handle_git_status_action(%EditorState{} = state, _action, _source), do: state

  @doc "Clears the live native panel if it belongs to the unloading source."
  @spec remove_git_status_source(state(), Sidebar.source()) :: state()
  def remove_git_status_source(
        %EditorState{shell_runtime: %Runtime{state: %TraditionalState{}}} = state,
        source
      ) do
    case Sidebar.get(Sidebar.table_for(state), @git_status_id) do
      %{source: ^source, visible?: true} -> close_git_status(state)
      _ -> state
    end
  end

  def remove_git_status_source(%EditorState{} = state, _source), do: state

  @doc "Returns the selected Traditional sidebar id."
  @spec active_id(state()) :: String.t() | nil
  def active_id(%EditorState{shell_runtime: %Runtime{state: %TraditionalState{} = shell_state}}),
    do: TraditionalState.sidebar_active_id(shell_state)

  def active_id(%EditorState{}), do: nil

  @doc "Selects a native sidebar and synchronizes registry focus."
  @spec select(state(), String.t() | nil) :: state()
  def select(%EditorState{} = state, id) when is_binary(id) or is_nil(id) do
    sync_file_tree_sidebar(state)
    sync_active_sidebar(state, id)
    update(state, &TraditionalState.select_sidebar(&1, id))
  end

  @doc "Returns the Traditional Git status panel."
  @spec git_status_panel(state()) :: GitStatusPanel.t() | nil
  def git_status_panel(%EditorState{
        shell_runtime: %Runtime{state: %TraditionalState{} = shell_state}
      }),
      do: TraditionalState.git_status_panel(shell_state)

  def git_status_panel(%EditorState{}), do: nil

  @doc "Replaces the exact panel, also allowing core fixtures to install a visible panel."
  @spec replace_git_status(state(), GitStatusPanel.t() | nil) :: state()
  def replace_git_status(%EditorState{} = state, nil) do
    sync_git_status_sidebar(state, nil, false)
    update(state, &TraditionalState.replace_git_status_panel(&1, nil))
  end

  def replace_git_status(%EditorState{} = state, %GitStatusPanel{} = panel) do
    panel = GitStatusPanel.reinstall(panel)

    case install_git_status(state, panel, is_nil(git_status_panel(state))) do
      {:ok, new_state} -> new_state
      {:error, _reason} -> state
    end
  end

  @doc "Updates the displayed repository snapshot without reopening Git status."
  @spec refresh_git_status(state(), GitStatusPanel.t()) :: state()
  def refresh_git_status(%EditorState{} = state, %GitStatusPanel{} = panel) do
    case install_git_status(state, panel, false) do
      {:ok, new_state} -> new_state
      {:error, _reason} -> state
    end
  end

  @doc "Returns the TUI-specific Git status presentation value."
  @spec git_status_tui_state(state()) :: TUIState.t() | nil
  def git_status_tui_state(%EditorState{
        shell_runtime: %Runtime{state: %TraditionalState{} = shell_state}
      }),
      do: TraditionalState.git_status_tui_state(shell_state)

  def git_status_tui_state(%EditorState{}), do: nil

  @doc "Replaces the TUI-specific Git status presentation value."
  @spec replace_git_status_tui(state(), TUIState.t() | nil) :: state()
  def replace_git_status_tui(%EditorState{} = state, nil),
    do: update(state, &TraditionalState.replace_git_status_tui_state(&1, nil))

  def replace_git_status_tui(%EditorState{} = state, %TUIState{} = tui),
    do: update(state, &TraditionalState.replace_git_status_tui_state(&1, tui))

  @doc "Closes Git status and synchronizes its registered surface."
  @spec close_git_status(state()) :: state()
  def close_git_status(%EditorState{} = state) do
    sync_git_status_sidebar(state, nil, false)

    state =
      if state.workspace.keymap_scope == :git_status,
        do: EditorState.focus_keymap_scope(state, :editor),
        else: state

    state
    |> update(&TraditionalState.close_git_status_panel/1)
    |> Layout.invalidate()
  end

  @doc "Returns whether the Traditional Observatory is visible."
  @spec observatory_visible?(state()) :: boolean()
  def observatory_visible?(%EditorState{
        shell_runtime: %Runtime{state: %TraditionalState{} = shell_state}
      }),
      do: TraditionalState.observatory_visible?(shell_state)

  def observatory_visible?(%EditorState{}), do: false

  @doc "Returns the Observatory owner when Traditional is active."
  @spec observatory(state()) :: Observatory.t() | nil
  def observatory(%EditorState{
        shell_runtime: %Runtime{state: %TraditionalState{} = shell_state}
      }),
      do: TraditionalState.observatory(shell_state)

  def observatory(%EditorState{}), do: nil

  @doc "Opens or replaces Observatory after the caller creates its first timer."
  @spec open_observatory(state(), Observatory.timer() | nil) :: state()
  def open_observatory(%EditorState{} = state, timer) do
    case observatory(state) do
      %Observatory{} = observatory -> cancel_timer(Observatory.timer(observatory))
      nil -> :ok
    end

    sync_observatory_sidebar(state, true)
    update(state, &TraditionalState.open_observatory(&1, timer))
  end

  @doc "Closes Observatory, cancelling its timer and invalidating in-flight work."
  @spec close_observatory(state()) :: state()
  def close_observatory(%EditorState{} = state) do
    case observatory(state) do
      %Observatory{} = observatory -> cancel_timer(Observatory.timer(observatory))
      nil -> :ok
    end

    sync_observatory_sidebar(state, false)
    update(state, &TraditionalState.close_observatory/1)
  end

  @doc "Replaces Observatory data without changing refresh correlation."
  @spec replace_observatory_data(state(), MingaEditor.Observatory.Data.t() | nil) :: state()
  def replace_observatory_data(%EditorState{} = state, data),
    do: update(state, &TraditionalState.replace_observatory_data(&1, data))

  @doc "Shows or dismisses an Observatory inspection float."
  @spec inspect_observatory(state(), MingaEditor.Observatory.Inspection.t() | nil) :: state()
  def inspect_observatory(%EditorState{} = state, inspection),
    do: update(state, &TraditionalState.inspect_observatory(&1, inspection))

  @doc "Expires a matching refresh token and returns whether collection should start."
  @spec expire_observatory_refresh(state(), reference()) :: {:collect | :stale, state()}
  def expire_observatory_refresh(%EditorState{} = state, token) do
    transition_with_result(state, &TraditionalState.expire_observatory_refresh(&1, token))
  end

  @doc "Returns whether an Observatory collection token is still current."
  @spec observatory_collection_current?(state(), reference()) :: boolean()
  def observatory_collection_current?(%EditorState{} = state, token) do
    case observatory(state) do
      %Observatory{} = observatory -> Observatory.collecting?(observatory, token)
      nil -> false
    end
  end

  @doc "Completes a matching collection and installs the caller-created next timer."
  @spec complete_observatory_refresh(
          state(),
          reference(),
          MingaEditor.Observatory.Data.t(),
          Observatory.timer()
        ) :: {:accepted | :stale, state()}
  def complete_observatory_refresh(%EditorState{} = state, token, data, next_timer) do
    case transition_with_result(
           state,
           &TraditionalState.complete_observatory_refresh(&1, token, data, next_timer)
         ) do
      {:accepted, new_state} ->
        {:accepted, new_state}

      {:stale, new_state} ->
        {timer, _next_token} = next_timer
        cancel_timer(timer)
        {:stale, new_state}
    end
  end

  @spec git_status_available?(Sidebar.source()) :: boolean()
  defp git_status_available?(:builtin), do: true

  defp git_status_available?({:extension, _name} = source),
    do: CodeLease.source_status(source) == :active

  @spec apply_git_status_action(state(), String.t(), GitStatusPanel.t() | nil, Sidebar.source()) ::
          state()
  defp apply_git_status_action(
         %EditorState{workspace: %{keymap_scope: :git_status}} = state,
         "toggle",
         %GitStatusPanel{},
         _source
       ),
       do: close_git_status(state)

  defp apply_git_status_action(state, _action, %GitStatusPanel{}, _source),
    do: focus_git_status(state)

  defp apply_git_status_action(state, _action, nil, {:extension, _name}) do
    {state, _panel} = open_git_status(state)
    state
  end

  defp apply_git_status_action(state, _action, nil, :builtin), do: state

  @spec prepare_visible_git_commit(state()) :: {state(), commit_target()}
  defp prepare_visible_git_commit(state) do
    {state, panel} =
      case git_status_panel(state) do
        nil -> open_git_status(state)
        %GitStatusPanel{} = panel -> {focus_git_status(state), panel}
      end

    case panel do
      %GitStatusPanel{repo_state: :normal, git_root: root, last_commit_message: message}
      when is_binary(root) ->
        {state, {:ok, root, message}}

      %GitStatusPanel{repo_state: :not_a_repo} ->
        {state, :not_git}

      :repo_unavailable ->
        {state, :repo_unavailable}

      %GitStatusPanel{} ->
        git_status_unavailable(state)
    end
  end

  @spec open_git_status(state()) :: {state(), GitStatusPanel.t() | :repo_unavailable}
  defp open_git_status(state) do
    with {:ok, panel} <- load_git_status(EditorAPI.git_root(state)),
         {:ok, new_state} <- install_git_status(state, panel, false) do
      {focus_git_status(new_state), panel}
    else
      :repo_unavailable ->
        {NoticeWorkflow.publish(state, "Git.Repo not available"), :repo_unavailable}

      {:error, _reason} ->
        git_status_unavailable(state)
    end
  end

  @spec git_status_unavailable(state()) :: {state(), :repo_unavailable}
  defp git_status_unavailable(state),
    do: {NoticeWorkflow.publish(state, "Git Status is not available"), :repo_unavailable}

  @spec install_git_status(state(), GitStatusPanel.t(), boolean()) ::
          {:ok, state()} | {:error, term()}
  defp install_git_status(state, panel, install_fixture?) do
    with :ok <- sync_git_status_sidebar(state, panel, install_fixture?) do
      {:ok, update(state, &TraditionalState.replace_git_status_panel(&1, panel))}
    end
  end

  @spec load_git_status({:ok, String.t()} | :not_git) ::
          {:ok, GitStatusPanel.t()} | :repo_unavailable
  defp load_git_status(:not_git), do: {:ok, not_git_status_panel(nil)}

  defp load_git_status({:ok, root}) do
    case Git.lookup_repo(root) do
      nil -> :repo_unavailable
      pid -> {:ok, pid |> Git.repo_status_snapshot() |> GitStatusPanel.from_repo_status()}
    end
  end

  @spec not_git_status_panel(String.t() | nil) :: GitStatusPanel.t()
  defp not_git_status_panel(project_root) do
    GitStatusPanel.new(%{
      repo_state: :not_a_repo,
      branch: "",
      entry_base_path: project_root,
      last_commit_message: "",
      stash_count: 0
    })
  end

  @spec focus_git_status(state()) :: state()
  defp focus_git_status(state) do
    if state.workspace.keymap_scope == :git_status and active_id(state) == @git_status_id do
      state
    else
      state =
        if FileTreeState.visible?(state.workspace.file_tree),
          do: FileTree.close(state),
          else: state

      state
      |> EditorState.focus_keymap_scope(:git_status)
      |> select(@git_status_id)
      |> Layout.invalidate()
    end
  end

  @spec update(state(), (TraditionalState.t() -> TraditionalState.t())) :: state()
  defp update(%EditorState{} = state, transition) do
    shell_state = state.shell_runtime |> Runtime.state() |> transition.()

    %{
      state
      | shell_runtime:
          MingaEditor.Shell.Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }
  end

  @spec transition_with_result(
          state(),
          (TraditionalState.t() -> {term(), TraditionalState.t()})
        ) :: {term(), state()}
  defp transition_with_result(%EditorState{} = state, transition) do
    case Runtime.state(state.shell_runtime) do
      %TraditionalState{} = shell_state ->
        {result, shell_state} = transition.(shell_state)

        {result,
         %{
           state
           | shell_runtime:
               MingaEditor.Shell.Runtime.install_traditional_state(
                 state.shell_runtime,
                 shell_state
               )
         }}

      _extension_state ->
        {:stale, state}
    end
  end

  @spec sync_file_tree_sidebar(state()) :: :ok
  defp sync_file_tree_sidebar(state) do
    case FileTreeFeature.sync_sidebar(
           state.workspace.file_tree,
           state.extension_surfaces.sidebar_registry
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Log.warning(:editor, "File Tree sidebar sync failed: #{inspect(reason)}")
    end
  end

  @spec sync_active_sidebar(state(), String.t() | nil) :: :ok
  defp sync_active_sidebar(state, id) do
    case MingaEditor.Extension.Sidebar.focus_left(state.extension_surfaces.sidebar_registry, id) do
      :ok -> :ok
      {:error, reason} -> Log.warning(:editor, "Sidebar focus sync failed: #{inspect(reason)}")
    end
  end

  @spec sync_git_status_sidebar(state(), GitStatusPanel.t() | nil, boolean()) ::
          :ok | {:error, term()}
  defp sync_git_status_sidebar(state, panel, install_fixture?) do
    badge_count = if panel, do: length(panel.entries)
    focused? = active_id(state) == @git_status_id

    case Sidebar.sync_git_status(
           Sidebar.table_for(state),
           badge_count,
           focused?,
           install_fixture?
         ) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Log.warning(:editor, "Git Status sidebar sync failed: #{inspect(reason)}")
        error
    end
  end

  @spec sync_observatory_sidebar(state(), boolean()) :: :ok
  defp sync_observatory_sidebar(state, visible?) do
    case BuiltinSurfaces.sync_observatory(visible?, state.extension_surfaces.sidebar_registry) do
      :ok ->
        :ok

      {:error, reason} ->
        Log.warning(:editor, "Observatory sidebar sync failed: #{inspect(reason)}")
    end
  end

  @spec cancel_timer(reference() | nil) :: :ok
  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) when is_reference(timer) do
    Process.cancel_timer(timer)
    :ok
  end
end
