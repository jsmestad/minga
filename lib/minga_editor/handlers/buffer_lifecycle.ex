defmodule MingaEditor.Handlers.BufferLifecycle do
  @moduledoc """
  Buffer lifecycle operations: registration, file opening, session restore, swap recovery, and notification helpers.

  Extracted from `MingaEditor` to reduce the main editor module size. Functions here manage the lifecycle of editor buffers from creation through registration, including session persistence and swap file recovery.
  """

  alias Minga.Buffer
  alias Minga.Events
  alias Minga.FileRef
  alias Minga.Session

  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Commands
  alias MingaEditor.HighlightSync
  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Session, as: EditorSessionState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.UI.Notification
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
  @spec recover_swap_entries(state(), [Minga.Session.swap_entry()]) :: state()
  def recover_swap_entries(state, entries) do
    count = length(entries)

    state =
      MingaEditor.log_message(state, "Found #{count} file(s) with unsaved changes from a previous session")

    Enum.reduce(entries, state, &recover_swap_entry/2)
  end

  # Restores open files and cursor positions from the previous session.
  @doc false
  @spec restore_session(state()) :: state()
  def restore_session(state) do
    case Session.load(EditorSessionState.session_opts(state.session)) do
      {:ok, session} ->
        state = MingaEditor.log_message(state, "Restored from previous session")
        Enum.reduce(session.buffers, state, &restore_session_buffer/2)

      {:error, _} ->
        state
    end
  end

  @doc false
  @spec update_test_notification(state(), non_neg_integer()) :: state()
  def update_test_notification(state, 0) do
    put_notification(
      state,
      Notification.new(
        id: "build:test",
        level: :success,
        title: "Build finished",
        body: "Tests passed",
        source: "Build",
        auto_dismiss_ms: 4_000
      )
    )
  end

  def update_test_notification(state, exit_code) do
    put_notification(
      state,
      Notification.new(
        id: "build:test",
        level: :error,
        title: "Build failed",
        body: "Test command exited with code #{exit_code}",
        source: "Build",
        actions: [
          %{id: "show_logs", label: "Show logs", dispatch: {:command, :test_output}},
          %{id: "retry", label: "Retry", dispatch: {:command, :test_rerun}}
        ]
      )
    )
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

  # Refreshes the tool manager picker items if it's currently open.
  # Called when tool install events change tool status so the user
  # sees live updates (spinner -> checkmark, etc.).
  @doc false
  @spec maybe_refresh_tool_picker(state()) :: state()
  def maybe_refresh_tool_picker(
        %{
          shell_state: %{
            modal: {:picker, %{picker_ui: %{source: MingaEditor.UI.Picker.Sources.Tool}}}
          }
        } = state
      ) do
    PickerUI.refresh_items(state)
  end

  def maybe_refresh_tool_picker(state), do: state

  @doc false
  @spec maybe_check_swap_recovery(state()) :: :ok
  def maybe_check_swap_recovery(state) do
    if EditorSessionState.swap_enabled?(state.session) and state.backend != :headless do
      send(self(), :check_swap_recovery)
    end

    :ok
  end

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
    MingaEditor.log_message(state, "Opened (agent): #{file_path}")
  end

  # ── Private helpers ──────────────────────────────────────────────────

  @spec recover_swap_entry(Minga.Session.swap_entry(), state()) :: state()
  defp recover_swap_entry(entry, state) do
    case Minga.Session.recover_swap_file(entry.swap_path) do
      {:ok, file_path, content} ->
        state = MingaEditor.log_message(state, "Recovered: #{Path.basename(file_path)}")
        recover_buffer(state, file_path, content)

      {:error, reason} ->
        MingaEditor.log_message(state, "Failed to recover #{Path.basename(entry.path)}: #{inspect(reason)}")
    end
  end

  @spec restore_session_buffer(Session.buffer_entry(), state()) :: state()
  defp restore_session_buffer(%{file: file} = entry, state) do
    if File.exists?(file) do
      case Commands.start_buffer(file, EditorState.options_server(state)) do
        {:ok, pid} ->
          :ok = Buffer.move_to(pid, {entry.cursor_line, entry.cursor_col})
          register_buffer(state, pid, file)

        {:error, _} ->
          state
      end
    else
      state
    end
  end

  # Opens a file and replaces its content with recovered swap data.
  # The buffer is marked dirty since the recovered content hasn't been saved.
  @spec recover_buffer(state(), String.t(), String.t()) :: state()
  defp recover_buffer(state, file_path, content) do
    case Commands.start_buffer(file_path, EditorState.options_server(state)) do
      {:ok, pid} ->
        # Replace buffer content with the recovered swap data.
        # This marks the buffer dirty (unsaved changes from the crash).
        case Buffer.replace_content(pid, content, :recovery) do
          :ok ->
            register_buffer(state, pid, file_path)

          {:error, :read_only} ->
            MingaEditor.log_message(state, "Cannot recover #{Path.basename(file_path)}: read-only")
        end

      {:error, reason} ->
        MingaEditor.log_message(
          state,
          "Could not open buffer for #{Path.basename(file_path)}: #{inspect(reason)}"
        )
    end
  end

  # Shared buffer registration: adds buffer to the list, logs, refreshes
  # LSP status, and broadcasts :buffer_opened so event bus subscribers
  # (Git.Tracker, FileWatcher, Project, SyncServer, Config.Hooks) react.
  @spec register_buffer(state(), pid(), String.t()) :: state()
  defp register_buffer(state, buffer_pid, file_path) do
    state = Commands.add_buffer(state, buffer_pid)
    state = MingaEditor.log_message(state, "Opened: #{file_path}")

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

  @spec put_notification(state(), Notification.t()) :: state()
  defp put_notification(state, %Notification{} = notification) do
    notification = maybe_schedule_notification_dismiss(notification, state.backend)

    state
    |> log_notification(notification)
    |> EditorState.upsert_notification(notification)
  end

  @spec maybe_schedule_notification_dismiss(Notification.t(), EditorState.backend()) ::
          Notification.t()
  defp maybe_schedule_notification_dismiss(
         %Notification{auto_dismiss_ms: ms, id: id} = notification,
         backend
       )
       when is_integer(ms) and ms > 0 and backend != :headless do
    dismiss_ref = make_ref()
    Process.send_after(self(), {:dismiss_notification, id, dismiss_ref}, ms)
    Notification.with_dismiss_ref(notification, dismiss_ref)
  end

  defp maybe_schedule_notification_dismiss(%Notification{} = notification, _backend),
    do: notification

  @spec log_notification(state(), Notification.t()) :: state()
  defp log_notification(state, %Notification{} = notification) do
    source = if notification.source, do: "[#{notification.source}] ", else: ""
    body = if notification.body in [nil, ""], do: "", else: ": #{notification.body}"
    MingaEditor.log_message(state, "#{source}#{notification.title}#{body}")
  end

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
