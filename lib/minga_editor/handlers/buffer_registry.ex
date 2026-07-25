defmodule MingaEditor.Handlers.BufferRegistry do
  @moduledoc """
  Buffer registration and lookup: opening files, tracking buffers in the workspace, and deduplicating tab entries.

  Changes when: how we open, register, or track buffers changes.
  """

  alias Minga.Buffer
  alias Minga.Project.FileRef

  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Commands
  alias MingaEditor.HighlightSync
  alias MingaEditor.Shell.BufferMetadata
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Workflow, as: ShellWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.TabWorkflow
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.WorkspaceWorkflow
  alias Minga.Project.FileTree

  @typedoc "Editor state (same as `MingaEditor.state()`)."
  @type state :: EditorState.t()
  @type open_or_activate_status :: :opened | :activated | :switched_tab
  @type open_or_activate_option ::
          {:existing_target, :buffer | :tab}
          | {:options_server, GenServer.server() | nil}
          | {:start_opts, keyword()}
  @type open_or_activate_result ::
          {:ok, state(), pid(), open_or_activate_status()} | {:error, term()}

  # ── Public functions ──────────────────────────────────────────────────

  @doc "Applies the pure buffer-registration transition and creates its requested monitor."
  @spec add_buffer(state(), pid(), keyword()) :: state()
  def add_buffer(%EditorState{} = state, pid, opts \\ []) when is_pid(pid) and is_list(opts) do
    old_buffer = state.workspace.buffers.active
    state = ShellWorkflow.ensure_available(state)
    context = Keyword.get(opts, :context, state.buffer_lifecycle.buffer_add_context)
    metadata = prepare_buffer_metadata(state, pid, context)
    {transitioned, result} = EditorState.register_buffer(state, pid, context)

    {runtime, workspace} =
      Runtime.route_buffer_added(
        state.shell_runtime,
        state.workspace,
        transitioned.workspace,
        metadata
      )

    transitioned =
      EditorState.install_buffer_shell_transition(transitioned, runtime, workspace)

    next_state =
      state
      |> WorkspaceWorkflow.persist_changes(transitioned)
      |> HighlightSync.ensure_active_buffer_presentation(old_buffer)

    log_buffer_shell_transition(state, next_state, metadata)

    case result do
      :already_registered -> next_state
      {:monitor, monitored_pid} -> monitor_buffer(next_state, monitored_pid)
    end
  end

  @doc "Runs external cleanup around the pure retired-buffer root transition."
  @spec retire_dead_buffer(state(), pid()) :: state()
  def retire_dead_buffer(%EditorState{} = state, pid) when is_pid(pid) do
    state = ShellWorkflow.ensure_available(state)
    Minga.Log.info(:editor, "Buffer process #{inspect(pid)} died, removing from state")

    transitioned =
      state
      |> release_buffer_monitor(pid)
      |> HighlightSync.close_buffer(pid)
      |> EditorState.remove_buffer(pid)

    {runtime, workspace} =
      Runtime.route_buffer_died(transitioned.shell_runtime, transitioned.workspace, pid)

    transitioned =
      EditorState.install_buffer_shell_transition(transitioned, runtime, workspace)

    WorkspaceWorkflow.persist_changes(state, transitioned)
  end

  @spec do_file_tree_open(state(), pid(), String.t(), FileTree.t()) :: state()
  def do_file_tree_open(state, pid, path, tree) do
    new_state = register_buffer(state, pid, path)

    file_tree = FileTreeState.set_tree(new_state.workspace.file_tree, FileTree.reveal(tree, path))
    workspace = MingaEditor.Session.State.set_file_tree(new_state.workspace, file_tree)
    %{new_state | workspace: workspace}
  end

  @spec open_file_by_path(state(), String.t()) :: state()
  def open_file_by_path(state, abs_path) do
    case open_file_by_path_result(state, abs_path) do
      {:ok, new_state} ->
        new_state

      {:error, _reason} ->
        MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "Could not open #{abs_path}")
    end
  end

  @spec open_file_by_path_result(state(), String.t()) :: {:ok, state()} | {:error, term()}
  def open_file_by_path_result(state, abs_path) do
    state = ShellWorkflow.ensure_available(state)

    case file_tab_for_path_in_active_workspace(state, abs_path) do
      %Tab{id: id} -> {:ok, TabWorkflow.switch(state, id)}
      nil -> start_and_register_file(state, abs_path)
    end
  end

  @spec open_or_activate_path(state(), String.t(), [open_or_activate_option()]) ::
          open_or_activate_result()
  def open_or_activate_path(state, abs_path, opts \\ [])

  def open_or_activate_path(%EditorState{} = state, abs_path, opts)
      when is_binary(abs_path) and is_list(opts) do
    with {:ok, opts} <- validate_open_or_activate_options(opts) do
      state = ShellWorkflow.ensure_available(state)
      existing_target = Keyword.get(opts, :existing_target, :buffer)
      options_server = Keyword.get(opts, :options_server, state.interaction.options_server)
      start_opts = Keyword.get(opts, :start_opts, [])

      case find_buffer_by_path(state, abs_path) do
        nil -> open_new_path_buffer(state, abs_path, options_server, start_opts)
        idx -> activate_path_buffer(state, idx, existing_target)
      end
    end
  end

  def open_or_activate_path(%EditorState{}, abs_path, _opts) when is_binary(abs_path),
    do: {:error, {:invalid_options, :not_a_keyword_list}}

  @spec start_and_register_file(state(), String.t()) :: {:ok, state()} | {:error, term()}
  def start_and_register_file(state, abs_path) do
    case Commands.start_buffer(abs_path, state.interaction.options_server,
           events_registry: state.extension_surfaces.events_registry
         ) do
      {:ok, pid} ->
        new_state = register_buffer(state, pid, abs_path)
        {:ok, AgentLifecycle.maybe_set_auto_context(new_state, abs_path, pid)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec file_tab_for_path_in_active_workspace(state(), String.t()) :: Tab.t() | nil
  def file_tab_for_path_in_active_workspace(
        %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state,
        path
      ) do
    file_ref = file_ref_for_path(state, path)

    if active_buffer_matches_file_ref?(state, file_ref) do
      Runtime.active_tab(state.shell_runtime)
    else
      workspace_id = TabBar.active_workspace_id(tb)

      TabBar.find_file_tab_in_workspace(tb, workspace_id, file_ref) ||
        find_file_tab_by_live_path(tb, workspace_id, path)
    end
  end

  def file_tab_for_path_in_active_workspace(_state, _path), do: nil

  @doc "Returns the index of the live buffer whose canonical path matches."
  @spec find_buffer_by_path(state() | map(), String.t()) :: non_neg_integer() | nil
  def find_buffer_by_path(%{workspace: %{buffers: %{list: buffers}}}, file_path) do
    Enum.find_index(buffers, &buffer_path_matches?(&1, file_path))
  end

  @doc "Creates one Editor-owned monitor and records its correlation reference."
  @spec monitor_buffer(state(), pid() | term()) :: state()
  def monitor_buffer(%EditorState{} = state, pid) when is_pid(pid) do
    if Map.has_key?(state.buffer_lifecycle.buffer_monitors, pid) do
      state
    else
      %{
        state
        | buffer_lifecycle:
            MingaEditor.State.BufferLifecycle.record_monitor(
              state.buffer_lifecycle,
              pid,
              Process.monitor(pid)
            )
      }
    end
  end

  def monitor_buffer(%EditorState{} = state, _pid), do: state

  @doc "Creates Editor-owned monitors for every untracked buffer pid."
  @spec monitor_buffers(state(), [pid()]) :: state()
  def monitor_buffers(%EditorState{} = state, pids) when is_list(pids) do
    Enum.reduce(pids, state, &monitor_buffer(&2, &1))
  end

  @spec buffer_inventory(state()) :: [pid()]
  def buffer_inventory(%EditorState{} = state) do
    active_pids = Enum.filter(state.workspace.buffers.list, &is_pid/1)
    Enum.uniq(active_pids ++ inactive_file_tab_buffer_pids(state, active_tab_id(state)))
  end

  @spec buffer_tracked?(state(), pid()) :: boolean()
  def buffer_tracked?(state, pid) when is_pid(pid) do
    pid in buffer_inventory(state)
  end

  # Like register_buffer but adds the buffer in the background without
  # switching the active window. Used by ensure_buffer_for_path so agent
  # edits don't yank the user away from their current file.
  # Skips code_lens/inlay_hint scheduling; those are lazy-loaded when
  # the user explicitly opens the buffer.
  @spec register_buffer_background(state(), pid(), String.t()) :: state()
  def register_buffer_background(state, buffer_pid, file_path) do
    buffers = Buffers.add_background(state.workspace.buffers, buffer_pid)
    workspace = MingaEditor.Session.State.set_buffers(state.workspace, buffers)
    state = %{state | workspace: workspace}

    state = MingaEditor.Handlers.BufferRegistry.monitor_buffer(state, buffer_pid)
    Minga.Log.info(:editor, "Opened (agent): #{file_path}")
    state
  end

  @spec register_buffer(state(), pid(), String.t(), keyword()) :: state()
  def register_buffer(state, buffer_pid, file_path, opts \\ []) do
    state = Commands.add_buffer(state, buffer_pid)
    Minga.Log.info(:editor, "Opened: #{file_path}")

    if state.frontend.backend != :headless and Keyword.get(opts, :schedule_lsp_refresh?, true) do
      Process.send_after(self(), :request_code_lens_and_inlay_hints, 800)
    end

    state
  end

  # ── Private helpers ──────────────────────────────────────────────────

  @spec release_buffer_monitor(state(), pid()) :: state()
  defp release_buffer_monitor(%EditorState{} = state, buffer_pid) do
    case Map.get(state.buffer_lifecycle.buffer_monitors, buffer_pid) do
      ref when is_reference(ref) ->
        Process.demonitor(ref, [:flush])
        state

      nil ->
        state
    end
  end

  @spec open_new_path_buffer(state(), String.t(), term(), keyword()) :: open_or_activate_result()
  defp open_new_path_buffer(state, abs_path, options_server, start_opts) do
    case Commands.start_buffer(abs_path, options_server, start_opts) do
      {:ok, pid} -> {:ok, add_buffer(state, pid), pid, :opened}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec activate_path_buffer(state(), non_neg_integer(), :buffer | :tab) ::
          open_or_activate_result()
  defp activate_path_buffer(state, idx, :tab) do
    pid = Enum.at(state.workspace.buffers.list, idx)
    {state, tab} = ShellWorkflow.resolve_tab_by_buffer(state, pid)

    case tab do
      %Tab{id: tab_id} -> {:ok, TabWorkflow.switch(state, tab_id), pid, :switched_tab}
      _ -> activate_path_buffer(state, idx, :buffer)
    end
  end

  defp activate_path_buffer(state, idx, :buffer) do
    pid = Enum.at(state.workspace.buffers.list, idx)
    {:ok, MingaEditor.BufferActivation.activate(state, idx), pid, :activated}
  end

  @spec validate_open_or_activate_options(list()) ::
          {:ok, [open_or_activate_option()]} | {:error, term()}
  defp validate_open_or_activate_options(opts) do
    if Keyword.keyword?(opts) do
      do_validate_open_or_activate_options(opts)
    else
      {:error, {:invalid_options, :not_a_keyword_list}}
    end
  end

  @spec do_validate_open_or_activate_options(keyword()) ::
          {:ok, [open_or_activate_option()]} | {:error, term()}
  defp do_validate_open_or_activate_options(opts) do
    with :ok <- validate_open_or_activate_keys(opts),
         :ok <- validate_open_or_activate_values(opts) do
      {:ok, opts}
    end
  end

  @spec validate_open_or_activate_keys(keyword()) :: :ok | {:error, term()}
  defp validate_open_or_activate_keys(opts) do
    case Keyword.keys(opts) -- [:existing_target, :options_server, :start_opts] do
      [] -> :ok
      [key | _] -> {:error, {:invalid_option, key}}
    end
  end

  @spec validate_open_or_activate_values(keyword()) :: :ok | {:error, term()}
  defp validate_open_or_activate_values(opts) do
    cond do
      Keyword.get(opts, :existing_target, :buffer) not in [:buffer, :tab] ->
        {:error, {:invalid_option, :existing_target}}

      not valid_options_server?(Keyword.get(opts, :options_server, nil)) ->
        {:error, {:invalid_option, :options_server}}

      not Keyword.keyword?(Keyword.get(opts, :start_opts, [])) ->
        {:error, {:invalid_option, :start_opts}}

      true ->
        :ok
    end
  end

  @spec valid_options_server?(GenServer.server() | nil | term()) :: boolean()
  defp valid_options_server?(nil), do: true
  defp valid_options_server?(server) when is_pid(server) or is_atom(server), do: true
  defp valid_options_server?({:global, _name}), do: true
  defp valid_options_server?({:via, module, _name}) when is_atom(module), do: true
  defp valid_options_server?(_server), do: false

  @spec prepare_buffer_metadata(
          state(),
          pid(),
          MingaEditor.Shell.buffer_add_context()
        ) :: BufferMetadata.t()
  defp prepare_buffer_metadata(%EditorState{} = state, buffer_pid, context) do
    path = live_buffer_path(buffer_pid)
    label = live_buffer_label(buffer_pid, path)
    file_ref = buffer_file_ref(state, buffer_pid, path, label)
    BufferMetadata.new(buffer_pid, context, label, path, file_ref)
  end

  @spec live_buffer_path(pid()) :: String.t() | nil
  defp live_buffer_path(buffer_pid) do
    Buffer.file_path(buffer_pid)
  catch
    :exit, _reason -> nil
  end

  @spec live_buffer_label(pid(), String.t() | nil) :: String.t()
  defp live_buffer_label(buffer_pid, path) do
    case Buffer.buffer_name(buffer_pid) do
      name when is_binary(name) -> name
      _missing when is_binary(path) -> Path.basename(path)
      _missing -> "[no file]"
    end
  catch
    :exit, _reason -> "[dead]"
  end

  @spec buffer_file_ref(state(), pid(), String.t() | nil, String.t()) :: FileRef.t()
  defp buffer_file_ref(state, buffer_pid, path, label) do
    root = state.workspace.file_tree.project_root

    case {path, root} do
      {path, root} when is_binary(path) and is_binary(root) ->
        case FileRef.from_path(root, path) do
          {:ok, file_ref} -> file_ref
          {:error, :outside_project} -> FileRef.from_buffer(buffer_pid, label)
        end

      _missing_path_or_root ->
        FileRef.from_buffer(buffer_pid, label)
    end
  end

  @spec find_file_tab_by_live_path(TabBar.t(), non_neg_integer(), String.t()) :: Tab.t() | nil
  defp find_file_tab_by_live_path(tab_bar, workspace_id, path) do
    tab_bar
    |> TabBar.visible_file_tabs(workspace_id)
    |> Enum.find(&tab_path_matches?(&1, path))
  end

  @spec file_ref_for_path(state(), String.t()) :: FileRef.t()
  defp file_ref_for_path(state, path) when is_binary(path) do
    case state.workspace.file_tree.project_root do
      root when is_binary(root) ->
        case FileRef.from_path(root, path) do
          {:ok, file_ref} -> file_ref
          {:error, :outside_project} -> FileRef.from_file_path(path)
        end

      nil ->
        FileRef.from_file_path(path)
    end
  end

  @spec log_buffer_shell_transition(state(), state(), BufferMetadata.t()) :: :ok
  defp log_buffer_shell_transition(previous, current, %BufferMetadata{} = metadata) do
    previous_id = active_tab_id(previous)
    current_id = active_tab_id(current)

    Minga.Log.debug(:editor, fn ->
      "[tab] buffer_added label=#{metadata.label} path=#{inspect(metadata.path)} " <>
        "context=#{metadata.context} tab=#{inspect(previous_id)}->#{inspect(current_id)}"
    end)
  end

  @spec active_tab_id(state()) :: Tab.id() | nil
  defp active_tab_id(%EditorState{} = state) do
    case Runtime.active_tab(state.shell_runtime) do
      %Tab{id: id} -> id
      nil -> nil
    end
  end

  @spec inactive_file_tab_buffer_pids(state(), Tab.id() | nil) :: [pid()]
  defp inactive_file_tab_buffer_pids(_state, nil), do: []

  defp inactive_file_tab_buffer_pids(
         %{shell_runtime: %{state: %{tab_bar: %TabBar{tabs: tabs}}}},
         active_tab_id
       ) do
    Enum.flat_map(tabs, fn
      %Tab{id: ^active_tab_id} -> []
      %Tab{kind: :file, context: context} -> TabContext.buffer_pids(context)
      _tab -> []
    end)
  end

  defp inactive_file_tab_buffer_pids(_state, _active_tab_id), do: []

  @spec active_buffer_matches_file_ref?(state(), FileRef.t()) :: boolean()
  defp active_buffer_matches_file_ref?(
         %{workspace: %{buffers: %{active: active}}},
         %FileRef{} = file_ref
       )
       when is_pid(active) do
    case buffer_file_ref(active) do
      %FileRef{} = active_ref -> FileRef.equal?(active_ref, file_ref)
      nil -> false
    end
  end

  defp active_buffer_matches_file_ref?(_state, _file_ref), do: false

  @spec tab_path_matches?(Tab.t(), String.t()) :: boolean()
  defp tab_path_matches?(%Tab{context: context}, path) do
    Enum.any?(TabContext.buffer_pids(context), &buffer_path_matches?(&1, path))
  end

  defp tab_path_matches?(_tab, _path), do: false

  @spec buffer_path_matches?(pid(), String.t()) :: boolean()
  defp buffer_path_matches?(pid, path) do
    Buffer.file_path(pid) == path
  catch
    :exit, _reason -> false
  end

  @spec buffer_file_ref(pid()) :: FileRef.t() | nil
  defp buffer_file_ref(pid) when is_pid(pid) do
    case Buffer.file_path(pid) do
      path when is_binary(path) -> FileRef.from_file_path(path)
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end
end
