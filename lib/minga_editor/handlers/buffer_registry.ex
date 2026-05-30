defmodule MingaEditor.Handlers.BufferRegistry do
  @moduledoc """
  Buffer registration and lookup: opening files, tracking buffers in the workspace, and deduplicating tab entries.

  Changes when: how we open, register, or track buffers changes.
  """

  alias Minga.Buffer
  alias Minga.Events
  alias Minga.FileRef

  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Commands
  alias MingaEditor.HighlightSync
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias Minga.Project.FileTree

  @typedoc "Editor state (same as `MingaEditor.state()`)."
  @type state :: EditorState.t()

  # ── Public functions ──────────────────────────────────────────────────

  @doc false
  @spec do_file_tree_open(state(), pid(), String.t(), FileTree.t()) :: state()
  def do_file_tree_open(state, pid, path, tree) do
    new_state = register_buffer(state, pid, path)

    EditorState.update_file_tree(new_state, fn file_tree ->
      FileTreeState.set_tree(file_tree, FileTree.reveal(tree, path))
    end)
  end

  @doc false
  @spec open_file_by_path(state(), String.t()) :: state()
  def open_file_by_path(state, abs_path) do
    case open_file_by_path_result(state, abs_path) do
      {:ok, new_state} -> new_state
      {:error, _reason} -> EditorState.set_status(state, "Could not open #{abs_path}")
    end
  end

  @doc false
  @spec open_file_by_path_result(state(), String.t()) :: {:ok, state()} | {:error, term()}
  def open_file_by_path_result(state, abs_path) do
    case file_tab_for_path_in_active_workspace(state, abs_path) do
      %Tab{id: id} -> {:ok, EditorState.switch_tab(state, id)}
      nil -> start_and_register_file(state, abs_path)
    end
  end

  @doc false
  @spec start_and_register_file(state(), String.t()) :: {:ok, state()} | {:error, term()}
  def start_and_register_file(state, abs_path) do
    case Commands.start_buffer(abs_path, EditorState.options_server(state)) do
      {:ok, pid} ->
        new_state = register_buffer(state, pid, abs_path)
        {:ok, AgentLifecycle.maybe_set_auto_context(new_state, abs_path, pid)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec file_tab_for_path_in_active_workspace(state(), String.t()) :: Tab.t() | nil
  def file_tab_for_path_in_active_workspace(
        %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
        path
      ) do
    file_ref = FileRef.new(path)

    if active_buffer_matches_file_ref?(state, file_ref) do
      EditorState.active_tab(state)
    else
      TabBar.find_file_tab_in_workspace(tb, TabBar.active_workspace_id(tb), file_ref)
    end
  end

  def file_tab_for_path_in_active_workspace(_state, _path), do: nil

  @doc false
  @spec buffer_tracked?(state(), pid()) :: boolean()
  def buffer_tracked?(state, pid) when is_pid(pid) do
    pid in state.workspace.buffers.list or buffer_tracked_in_tabs?(state, pid)
  end

  # Like register_buffer but adds the buffer in the background without
  # switching the active window. Used by ensure_buffer_for_path so agent
  # edits don't yank the user away from their current file.
  # Skips code_lens/inlay_hint scheduling; those are lazy-loaded when
  # the user explicitly opens the buffer.
  @doc false
  @spec register_buffer_background(state(), pid(), String.t()) :: state()
  def register_buffer_background(state, buffer_pid, file_path) do
    state =
      EditorState.update_buffers(state, &Buffers.add_background(&1, buffer_pid))

    state = EditorState.monitor_buffer(state, buffer_pid)
    Minga.Log.info(:editor, "Opened (agent): #{file_path}")
    state
  end

  # Shared buffer registration: adds buffer to the list, logs, refreshes
  # LSP status, and broadcasts :buffer_opened so event bus subscribers
  # (Git.Tracker, FileWatcher, Project, SyncServer, Config.Hooks) react.
  @doc false
  @spec register_buffer(state(), pid(), String.t()) :: state()
  def register_buffer(state, buffer_pid, file_path) do
    state = Commands.add_buffer(state, buffer_pid)
    Minga.Log.info(:editor, "Opened: #{file_path}")

    Events.broadcast(
      :buffer_opened,
      %Events.BufferEvent{
        buffer: buffer_pid,
        path: file_path
      },
      EditorState.events_registry(state)
    )

    # Eagerly set up syntax highlighting for this specific buffer.
    # Uses the PID-targeted variant so each restored buffer gets its
    # own parse request, not just whoever is active last.
    state = HighlightSync.setup_for_buffer_pid(state, buffer_pid)

    # Schedule code lens and inlay hint requests after LSP clients connect.
    # The SyncServer handles didOpen via the event bus; by the time 800ms
    # elapses the LSP client should be ready to serve requests.
    if state.backend != :headless do
      Process.send_after(self(), :request_code_lens_and_inlay_hints, 800)
    end

    state
  end

  # ── Private helpers ──────────────────────────────────────────────────

  @spec buffer_tracked_in_tabs?(state(), pid()) :: boolean()
  defp buffer_tracked_in_tabs?(%{shell_state: %{tab_bar: %{tabs: tabs}}}, pid) do
    Enum.any?(tabs, fn tab -> pid in tab_buffer_list(tab) end)
  end

  defp buffer_tracked_in_tabs?(_state, _pid), do: false

  @spec tab_buffer_list(MingaEditor.State.Tab.t() | term()) :: [pid()]
  defp tab_buffer_list(%MingaEditor.State.Tab{context: context}) when is_map(context) do
    case TabContext.to_workspace_map(context) do
      %{buffers: %Buffers{list: buffers}} -> Enum.filter(buffers, &is_pid/1)
      _ -> []
    end
  end

  defp tab_buffer_list(_tab), do: []

  @spec active_buffer_matches_file_ref?(state(), FileRef.t()) :: boolean()
  defp active_buffer_matches_file_ref?(
         %{workspace: %{buffers: %{active: active}}},
         %FileRef{} = file_ref
       )
       when is_pid(active) do
    case buffer_file_ref(active) do
      %FileRef{} = active_ref -> FileRef.same?(active_ref, file_ref)
      nil -> false
    end
  end

  defp active_buffer_matches_file_ref?(_state, _file_ref), do: false

  @spec buffer_file_ref(pid()) :: FileRef.t() | nil
  defp buffer_file_ref(pid) when is_pid(pid) do
    case Buffer.file_path(pid) do
      path when is_binary(path) -> FileRef.new(path)
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end
end
