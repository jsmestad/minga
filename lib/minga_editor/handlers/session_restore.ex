defmodule MingaEditor.Handlers.SessionRestore do
  @moduledoc """
  Session persistence and swap file recovery: restoring open buffers from a previous session and recovering unsaved changes from swap files.

  Changes when: session persistence format or recovery logic changes.
  """

  alias Minga.Buffer
  alias Minga.Keymap.Active
  alias Minga.Keymap.Bindings
  alias Minga.Session
  alias Minga.Session.Layout
  alias Minga.Session.Pane
  alias Minga.Session.Snapshot

  alias MingaEditor.Commands
  alias MingaEditor.Handlers.BufferRegistry
  alias MingaEditor.Handlers.SessionHandler
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  @typedoc "Editor state (same as `MingaEditor.state()`)."
  @type state :: EditorState.t()

  # ── Public functions ──────────────────────────────────────────────────

  @doc "Loads this project's saved session and restores it."
  @spec restore_session(state()) :: state()
  def restore_session(state) do
    case Session.load(SessionHandler.project_session_opts(state)) do
      {:ok, session} -> apply_session_snapshot(state, session)
      {:error, _} -> state
    end
  end

  @doc """
  Applies an already-loaded session from the Editor process: reopens its files with their cursors, rebuilds its window splits with each window's cursor and scroll, focuses the window that had focus, and says in the echo area how many files came back.
  """
  @spec apply_session_snapshot(state(), Session.snapshot()) :: state()
  def apply_session_snapshot(state, %Snapshot{} = session) do
    pre_restore_buffers = state.workspace.buffers.list

    state = Enum.reduce(session.buffers, state, &restore_session_buffer/2)
    restored = length(state.workspace.buffers.list) - length(pre_restore_buffers)

    # Resolve every reopened file before switching tabs: each tab keeps its own buffer list.
    opened = opened_buffers(state)
    {layout, focus} = surviving_layout(session, opened)

    state =
      state
      |> restore_active_file(focused_file(session, layout, focus))
      |> restore_layout(layout, focus, opened)

    if state.frontend.backend != :headless and state.workspace.buffers.list != pre_restore_buffers do
      Process.send_after(self(), :request_code_lens_and_inlay_hints, 800)
    end

    announce_restore(state, restored)
  end

  @spec recover_swap_entries(state(), [Minga.Session.swap_entry()]) :: state()
  def recover_swap_entries(state, entries) do
    recovered =
      Enum.map(entries, fn entry -> {entry, Session.recover_swap_file(entry.swap_path)} end)

    apply_recovered_entries(state, recovered)
  end

  @doc "Applies already-read swap contents from the Editor process."
  @spec apply_recovered_entries(state(), [
          {Session.swap_entry(), {:ok, String.t(), String.t()} | {:error, term()}}
        ]) :: state()
  def apply_recovered_entries(state, entries) do
    Minga.Log.info(
      :editor,
      "Found #{length(entries)} file(s) with unsaved changes from a previous session"
    )

    Enum.reduce(entries, state, &apply_recovered_entry/2)
  end

  @doc "Schedules the startup read when there are swap files to scan or a project session to restore."
  @spec maybe_check_swap_recovery(state()) :: :ok
  def maybe_check_swap_recovery(state) do
    if SessionHandler.swap_recovery_enabled?(state) or SessionHandler.restore_enabled?(state) do
      send(self(), :check_swap_recovery)
    end

    :ok
  end

  # ── Private helpers ──────────────────────────────────────────────────

  @spec restore_session_buffer(Session.buffer_entry(), state()) :: state()
  defp restore_session_buffer(%{file: file} = entry, state) do
    if File.exists?(file) do
      case Commands.start_buffer(file, state.interaction.options_server,
             events_registry: state.extension_surfaces.events_registry
           ) do
        {:ok, pid} ->
          :ok = Buffer.move_to(pid, {entry.cursor_line, entry.cursor_col})
          BufferRegistry.register_buffer(state, pid, file, schedule_lsp_refresh?: false)

        {:error, _} ->
          state
      end
    else
      state
    end
  end

  @spec opened_buffers(state()) :: %{String.t() => pid()}
  defp opened_buffers(state) do
    for pid <- BufferRegistry.buffer_inventory(state),
        path = Buffer.file_path(pid),
        is_binary(path),
        into: %{},
        do: {path, pid}
  end

  # Drops the windows whose file did not reopen, and finds the focused window among the survivors.
  # When the focused window itself was dropped, focus goes to the first survivor.
  @spec surviving_layout(Snapshot.t(), %{String.t() => pid()}) ::
          {Layout.t() | nil, non_neg_integer()}
  defp surviving_layout(%Snapshot{layout: nil}, _opened), do: {nil, 0}

  defp surviving_layout(%Snapshot{layout: layout, active_pane: active_pane}, opened) do
    focused = Enum.at(Layout.panes(layout), active_pane)

    case Layout.filter(layout, &Map.has_key?(opened, &1.file)) do
      nil -> {nil, 0}
      kept -> {kept, Enum.find_index(Layout.panes(kept), &(&1 == focused)) || 0}
    end
  end

  # The focused window's file decides which tab the layout lands in.
  @spec focused_file(Snapshot.t(), Layout.t() | nil, non_neg_integer()) :: String.t() | nil
  defp focused_file(session, nil, _focus), do: session.active_file
  defp focused_file(_session, layout, focus), do: Enum.at(Layout.panes(layout), focus).file

  # Rebuilds the saved splits in the active tab: the first pane reuses the focused window, the rest get new windows.
  @spec restore_layout(state(), Layout.t() | nil, non_neg_integer(), %{String.t() => pid()}) ::
          state()
  defp restore_layout(state, nil, _focus, _opened), do: state

  defp restore_layout(state, layout, focus, opened) do
    state = adopt_layout_buffers(state, layout, opened)
    windows = state.workspace.windows
    {tree, {windows, _reuse}} = place(layout, {windows, [windows.active]}, opened)
    leaves = WindowTree.leaves(tree)
    tops = Enum.zip(leaves, Enum.map(Layout.panes(layout), & &1.top))
    focused = Enum.at(leaves, focus)

    windows = windows |> Windows.set_tree(tree) |> Windows.set_active(focused)
    {:ok, %Window{content: {:buffer, buffer}, cursor: cursor}} = Windows.fetch(windows, focused)
    :ok = Buffer.move_to(buffer, cursor)

    workspace = MingaEditor.Session.State.set_windows(state.workspace, windows)
    state = MingaEditor.Layout.fit_windows(%{state | workspace: workspace})

    # Fitting gives each window a fresh viewport, so the saved scroll goes back on afterwards.
    windows =
      Enum.reduce(tops, state.workspace.windows, fn {id, top}, acc ->
        {:ok, window} = Windows.fetch(acc, id)
        Windows.set_viewport(acc, id, Viewport.put_top(window.viewport, top))
      end)

    %{state | workspace: MingaEditor.Session.State.set_windows(state.workspace, windows)}
  end

  # Every buffer a restored window shows joins the active tab's buffer list.
  # A window never shows a buffer its tab does not hold.
  @spec adopt_layout_buffers(state(), Layout.t(), %{String.t() => pid()}) :: state()
  defp adopt_layout_buffers(state, layout, opened) do
    buffers =
      layout
      |> Layout.panes()
      |> Enum.map(&Map.fetch!(opened, &1.file))
      |> Enum.uniq()
      |> Enum.reject(&(&1 in state.workspace.buffers.list))
      |> Enum.reduce(state.workspace.buffers, &Buffers.add_background(&2, &1))

    %{state | workspace: MingaEditor.Session.State.set_buffers(state.workspace, buffers)}
  end

  @spec place(Layout.t(), {Windows.t(), [Window.id()]}, %{String.t() => pid()}) ::
          {MingaEditor.WindowTree.t(), {Windows.t(), [Window.id()]}}
  defp place({:pane, %Pane{} = pane}, {windows, reuse}, opened) do
    {id, windows, reuse} =
      case reuse do
        [id] ->
          {id, windows, []}

        [] ->
          {id, windows} = Windows.allocate_id(windows)
          {id, windows, []}
      end

    buffer = Map.fetch!(opened, pane.file)
    window = Window.new(id, buffer, 24, 80, {pane.cursor_line, pane.cursor_col})

    windows =
      case Windows.fetch(windows, id) do
        {:ok, _old} -> Windows.replace_window(windows, id, window)
        :error -> Windows.add_window(windows, window)
      end

    {{:leaf, id}, {windows, reuse}}
  end

  defp place({:split, direction, first, second, size}, acc, opened) do
    {first, acc} = place(first, acc, opened)
    {second, acc} = place(second, acc, opened)
    {{:split, direction, first, second, size}, acc}
  end

  @spec announce_restore(state(), non_neg_integer()) :: state()
  defp announce_restore(state, 0), do: state

  defp announce_restore(state, count) do
    files = if count == 1, do: "1 file", else: "#{count} files"
    Minga.Log.info(:editor, "Restored #{files} from last time")

    NoticeWorkflow.publish(
      state,
      "Restored #{files} from last time" <> fresh_hint()
    )
  end

  # The hint names the live binding, so a user override shows up here too.
  @spec fresh_hint() :: String.t()
  defp fresh_hint do
    case Bindings.sequences_for_command(Active.leader_trie(), :session_start_fresh) do
      [keys | _rest] -> " · SPC #{Bindings.format_sequence(keys)} start fresh"
      [] -> ""
    end
  catch
    :exit, _ -> ""
  end

  @spec restore_active_file(state(), String.t() | nil) :: state()
  defp restore_active_file(state, nil), do: state

  defp restore_active_file(state, active_file) do
    case BufferRegistry.file_tab_for_path_in_active_workspace(state, active_file) do
      %{id: tab_id} ->
        MingaEditor.TabWorkflow.switch(state, tab_id)

      nil ->
        Minga.Log.warning(:editor, "Session active file no longer exists: #{active_file}")
        state
    end
  end

  @spec apply_recovered_entry(
          {Session.swap_entry(), {:ok, String.t(), String.t()} | {:error, term()}},
          state()
        ) :: state()
  defp apply_recovered_entry({_entry, {:ok, file_path, content}}, state) do
    Minga.Log.info(:editor, "Recovered: #{Path.basename(file_path)}")
    recover_buffer(state, file_path, content)
  end

  defp apply_recovered_entry({entry, {:error, reason}}, state) do
    Minga.Log.info(
      :editor,
      "Failed to recover #{Path.basename(entry.path)}: #{inspect(reason)}"
    )

    state
  end

  # Opens a file and replaces its content with recovered swap data.
  # The buffer is marked dirty since the recovered content hasn't been saved.
  @spec recover_buffer(state(), String.t(), String.t()) :: state()
  defp recover_buffer(state, file_path, content) do
    case Commands.start_buffer(file_path, state.interaction.options_server,
           events_registry: state.extension_surfaces.events_registry
         ) do
      {:ok, pid} ->
        # Replace buffer content with the recovered swap data.
        # This marks the buffer dirty (unsaved changes from the crash).
        case Buffer.replace_content(pid, content, :recovery) do
          :ok ->
            BufferRegistry.register_buffer(state, pid, file_path)

          {:error, :read_only} ->
            Minga.Log.info(
              :editor,
              "Cannot recover #{Path.basename(file_path)}: read-only"
            )

            state
        end

      {:error, reason} ->
        Minga.Log.info(
          :editor,
          "Could not open buffer for #{Path.basename(file_path)}: #{inspect(reason)}"
        )

        state
    end
  end
end
