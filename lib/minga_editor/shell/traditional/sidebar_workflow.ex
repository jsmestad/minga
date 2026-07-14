defmodule MingaEditor.Shell.Traditional.SidebarWorkflow do
  @moduledoc """
  Effect boundary for Traditional sidebar selection and built-in surfaces.

  Registry synchronization, logging, and timer cancellation stay here. The
  immutable sidebar and Observatory transitions remain in their value owners.
  """

  alias Minga.Log
  alias MingaEditor.GitStatus.Panel, as: GitStatusPanel
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.Observatory
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Sidebar.BuiltinSurfaces
  alias MingaEditor.State, as: EditorState

  @type state :: EditorState.t()

  @doc "Returns the selected Traditional sidebar id."
  @spec active_id(state()) :: String.t() | nil
  def active_id(%EditorState{shell_runtime: %Runtime{state: %TraditionalState{} = shell_state}}),
    do: TraditionalState.sidebar_active_id(shell_state)

  def active_id(%EditorState{}), do: nil

  @doc "Selects a native sidebar and synchronizes registry focus."
  @spec select(state(), String.t() | nil) :: state()
  def select(%EditorState{} = state, id) when is_binary(id) or is_nil(id) do
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

  @doc "Replaces Git status and synchronizes its registered surface."
  @spec replace_git_status(state(), GitStatusPanel.t() | map() | nil) :: state()
  def replace_git_status(%EditorState{} = state, panel) do
    panel = if is_nil(panel), do: nil, else: GitStatusPanel.new(panel)
    sync_git_status_sidebar(state, panel)
    update(state, &TraditionalState.replace_git_status_panel(&1, panel))
  end

  @doc "Returns the TUI-specific Git status presentation value."
  @spec git_status_tui_state(state()) :: struct() | nil
  def git_status_tui_state(%EditorState{
        shell_runtime: %Runtime{state: %TraditionalState{} = shell_state}
      }),
      do: TraditionalState.git_status_tui_state(shell_state)

  def git_status_tui_state(%EditorState{}), do: nil

  @doc "Replaces the TUI-specific Git status presentation value."
  @spec replace_git_status_tui(state(), struct() | nil) :: state()
  def replace_git_status_tui(%EditorState{} = state, tui),
    do: update(state, &TraditionalState.replace_git_status_tui_state(&1, tui))

  @doc "Closes Git status and synchronizes its registered surface."
  @spec close_git_status(state()) :: state()
  def close_git_status(%EditorState{} = state) do
    sync_git_status_sidebar(state, nil)
    update(state, &TraditionalState.close_git_status_panel/1)
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

  @spec update(state(), (TraditionalState.t() -> TraditionalState.t())) :: state()
  defp update(%EditorState{} = state, transition) do
    runtime = Runtime.update_traditional_state(state.shell_runtime, transition)
    EditorState.apply_shell_runtime_transition(state, runtime)
  end

  @spec transition_with_result(
          state(),
          (TraditionalState.t() -> {term(), TraditionalState.t()})
        ) :: {term(), state()}
  defp transition_with_result(%EditorState{} = state, transition) do
    case Runtime.state(state.shell_runtime) do
      %TraditionalState{} = shell_state ->
        {result, shell_state} = transition.(shell_state)

        runtime =
          Runtime.update_traditional_state(state.shell_runtime, fn _current -> shell_state end)

        {result, EditorState.apply_shell_runtime_transition(state, runtime)}

      _extension_state ->
        {:stale, state}
    end
  end

  @spec sync_active_sidebar(state(), String.t() | nil) :: :ok
  defp sync_active_sidebar(state, id) do
    case MingaEditor.Extension.Sidebar.focus_left(EditorState.sidebar_registry(state), id) do
      :ok -> :ok
      {:error, reason} -> Log.warning(:editor, "Sidebar focus sync failed: #{inspect(reason)}")
    end
  end

  @spec sync_git_status_sidebar(state(), GitStatusPanel.t() | nil) :: :ok
  defp sync_git_status_sidebar(state, panel) do
    case BuiltinSurfaces.sync_git_status_panel(panel, EditorState.sidebar_registry(state)) do
      :ok ->
        :ok

      {:error, reason} ->
        Log.warning(:editor, "Git Status sidebar sync failed: #{inspect(reason)}")
    end
  end

  @spec sync_observatory_sidebar(state(), boolean()) :: :ok
  defp sync_observatory_sidebar(state, visible?) do
    case BuiltinSurfaces.sync_observatory(visible?, EditorState.sidebar_registry(state)) do
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
