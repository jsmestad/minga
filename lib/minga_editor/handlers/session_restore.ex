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

  @typedoc "A swap file found at startup, with its file path and unsaved text or the reason it could not be read."
  @type recovered_entry ::
          {Session.swap_entry(), {:ok, String.t(), String.t()} | {:error, term()}}

  @typedoc """
  What one start has to pick up: the project's saved session, the unsaved text of its swap files, the swap files it holds back, and how many other files have unsaved text waiting.
  """
  @type resume :: %{
          snapshot: Snapshot.t() | nil,
          recovered: [recovered_entry()],
          held_back: [Session.swap_entry()],
          waiting_elsewhere: non_neg_integer(),
          waiting_projects: [Session.waiting_project()]
        }

  # ── Public functions ──────────────────────────────────────────────────

  @doc "Loads this project's saved session and restores it. Does nothing with session persistence off."
  @spec restore_session(state()) :: state()
  def restore_session(state) do
    if MingaEditor.State.Session.enabled?(state.session) do
      case Session.load(SessionHandler.project_session_opts(state)) do
        {:ok, session} -> apply_session_snapshot(state, session)
        {:error, _} -> state
      end
    else
      state
    end
  end

  @doc """
  Picks up where the last run stopped, in one step: restores the saved session first, then puts the unsaved text of each swap file into its buffer, and says once what came back.

  A file with unsaved text that the session did not hold is opened as well. Each buffer takes ownership of its text on disk (`Minga.Buffer.adopt_recovered_text/3`), so the swap it came from is removed only once the text is safe again. Text that cannot be shown stays in its swap file and is offered on the next start.

  Unsaved text whose file was written after the swap is held back: the file holds newer text, so the swap stays on disk and a `*Messages*` line says where.
  """
  @spec resume(state(), resume()) :: state()
  def resume(state, %{snapshot: snapshot, recovered: recovered} = resume) do
    {state, restored} = restore_snapshot(state, snapshot)
    {state, recovered_count} = recover_entries(state, recovered)
    :ok = announce_held_back(resume.held_back)
    :ok = announce_waiting_elsewhere(resume.waiting_elsewhere)

    state
    |> EditorState.mark_home_waiting(resume.waiting_projects)
    |> announce(restored, recovered_count)
  end

  @doc """
  Puts the unsaved text of one waiting swap file into a buffer for its file and shows that buffer.

  This is the user's own choice from the list of waiting text, so it also applies to text that a start held back, and to a file or directory that no longer exists. The buffer becomes the owner of the text on disk. A buffer that has unsaved changes of its own keeps them, and the swap stays.
  """
  @spec recover_waiting(state(), Session.swap_entry()) :: state()
  def recover_waiting(state, %{path: path, swap_path: swap_path}) do
    name = Path.basename(path)

    with {:ok, file_path, content} <- Session.read_swap_file(swap_path),
         {:ok, buffer} <- adopt(state, file_path, content, swap_path) do
      Minga.Log.info(:editor, "Recovered unsaved text: #{file_path}")

      state
      |> show_in_front(buffer, file_path)
      |> NoticeWorkflow.publish(
        "Recovered the unsaved text of #{name}: save to keep it, undo to drop it"
      )
    else
      {:error, :modified} ->
        NoticeWorkflow.publish(
          state,
          "#{name} has unsaved changes of its own: save or discard them, then recover again"
        )

      # The swap is gone: another editor or a start recovered or removed it after the list was read.
      {:error, :enoent} ->
        NoticeWorkflow.publish(state, "The unsaved text of #{name} is no longer waiting")

      {:error, reason} ->
        Minga.Log.warning(
          :editor,
          "#{not_recovered(path, reason)} The unsaved text stays in #{swap_path}."
        )

        NoticeWorkflow.publish(
          state,
          "Could not recover the unsaved text of #{name}. It is kept."
        )
    end
  end

  @doc """
  Applies an already-loaded session from the Editor process: reopens its files with their cursors, rebuilds its window splits with each window's cursor and scroll, focuses the window that had focus, and says in the echo area how many files came back.
  """
  @spec apply_session_snapshot(state(), Session.snapshot()) :: state()
  def apply_session_snapshot(state, %Snapshot{} = session) do
    {state, restored} = restore_snapshot(state, session)
    announce(state, restored, 0)
  end

  @doc "Puts already-read swap text into its buffers from the Editor process, and says how many files got their unsaved text back."
  @spec apply_recovered_entries(state(), [recovered_entry()]) :: state()
  def apply_recovered_entries(state, entries) do
    {state, recovered_count} = recover_entries(state, entries)
    announce(state, 0, recovered_count)
  end

  @spec restore_snapshot(state(), Snapshot.t() | nil) :: {state(), non_neg_integer()}
  defp restore_snapshot(state, nil), do: {state, 0}

  defp restore_snapshot(state, %Snapshot{} = session) do
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

    {state, restored}
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

  # One notice for one start: what was restored and what was recovered, never two competing messages.
  @spec announce(state(), non_neg_integer(), non_neg_integer()) :: state()
  defp announce(state, 0, 0), do: state

  defp announce(state, restored, recovered) do
    text = resume_text(restored, recovered)
    Minga.Log.info(:editor, text)
    hint = if restored > 0, do: fresh_hint(), else: ""
    NoticeWorkflow.publish(state, text <> hint)
  end

  @spec resume_text(non_neg_integer(), non_neg_integer()) :: String.t()
  defp resume_text(restored, 0), do: "Restored #{files(restored)} from last time"
  defp resume_text(0, recovered), do: "Recovered unsaved text in #{files(recovered)}"

  defp resume_text(restored, recovered) do
    "Restored #{files(restored)} from last time · recovered unsaved text in #{files(recovered)}"
  end

  @spec files(pos_integer()) :: String.t()
  defp files(1), do: "1 file"
  defp files(count), do: "#{count} files"

  # A file that was written after its swap holds newer text than the swap, so the swap's text is not put back.
  # It stays on disk, and the user is told where.
  @spec announce_held_back([Session.swap_entry()]) :: :ok
  defp announce_held_back(entries) do
    Enum.each(entries, fn entry -> Minga.API.message(held_back_line(entry.path)) end)
  end

  # Unsaved text that belongs somewhere else is never recovered into this start, so say that it exists.
  @spec announce_waiting_elsewhere(non_neg_integer()) :: :ok
  defp announce_waiting_elsewhere(count) do
    case waiting_elsewhere_line(count) do
      nil -> :ok
      line -> Minga.API.message(line)
    end
  end

  @doc """
  The `*Messages*` line for unsaved text that a start held back because its file changed afterwards.

  It names the key that lists the waiting text, read from the live keymap, so a rebind shows up in it.
  """
  @spec held_back_line(String.t()) :: String.t()
  def held_back_line(path) when is_binary(path) do
    hint = unsaved_text_hint("; recover or discard it with")
    "#{path} changed after its unsaved text was kept, so the text was not put back#{hint}"
  end

  @doc """
  The `*Messages*` line for unsaved text of `count` files that this start does not recover, or `nil` when there is none.

  It names the key that lists the waiting text, read from the live keymap, so a rebind shows up in it.
  """
  @spec waiting_elsewhere_line(non_neg_integer()) :: String.t() | nil
  def waiting_elsewhere_line(0), do: nil

  def waiting_elsewhere_line(1) do
    "Unsaved text of 1 other file is waiting; open its project or the file to recover it" <>
      unsaved_text_hint(", or list it with")
  end

  def waiting_elsewhere_line(count) when is_integer(count) and count > 1 do
    "Unsaved text of #{count} other files is waiting; open their project or the files to recover it" <>
      unsaved_text_hint(", or list it with")
  end

  # Names the live binding of the list of waiting unsaved text, so a user override shows up here too.
  @spec unsaved_text_hint(String.t()) :: String.t()
  defp unsaved_text_hint(lead) do
    case Bindings.sequences_for_command(Active.leader_trie(), :unsaved_text) do
      [keys | _rest] -> "#{lead} SPC #{Bindings.format_sequence(keys)}"
      [] -> ""
    end
  catch
    :exit, _ -> ""
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

  @spec recover_entries(state(), [recovered_entry()]) :: {state(), non_neg_integer()}
  defp recover_entries(state, entries), do: Enum.reduce(entries, {state, 0}, &recover_entry/2)

  @spec recover_entry(recovered_entry(), {state(), non_neg_integer()}) ::
          {state(), non_neg_integer()}
  defp recover_entry({entry, {:ok, file_path, content}}, {state, count}) do
    case adopt(state, file_path, content, entry.swap_path) do
      {:ok, buffer} ->
        Minga.Log.info(:editor, "Recovered unsaved text: #{file_path}")
        {show_recovered(state, buffer, file_path), count + 1}

      {:error, reason} ->
        Minga.Log.warning(
          :editor,
          "#{not_recovered(file_path, reason)} The unsaved text stays in #{entry.swap_path}."
        )

        {state, count}
    end
  end

  defp recover_entry({entry, {:error, reason}}, {state, count}) do
    Minga.Log.warning(
      :editor,
      "Could not read the unsaved text of #{entry.path} from #{entry.swap_path}: #{inspect(reason)}"
    )

    {state, count}
  end

  @spec not_recovered(String.t(), term()) :: String.t()
  defp not_recovered(file_path, :modified),
    do:
      "#{file_path} has newer unsaved changes, so its text from before the crash was not restored."

  defp not_recovered(file_path, :read_only),
    do: "#{file_path} is read-only, so its unsaved text was not restored."

  defp not_recovered(file_path, reason),
    do: "Could not open #{file_path} to restore its unsaved text (#{inspect(reason, limit: 5)})."

  # Gives the text to the buffer for the file: the one that is already open, or a new one.
  # A file that no longer exists gets a buffer for its path, so the text can be saved back.
  @spec adopt(state(), String.t(), String.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  defp adopt(state, file_path, content, swap_path) do
    with {:ok, buffer} <- buffer_for(state, file_path),
         :ok <- Buffer.adopt_recovered_text(buffer, content, swap_path) do
      {:ok, buffer}
    end
  catch
    # The buffer can stop between its lookup or start and the call.
    :exit, reason -> {:error, {:exit, reason}}
  end

  @spec buffer_for(state(), String.t()) :: {:ok, pid()} | {:error, term()}
  defp buffer_for(state, file_path) do
    case Buffer.pid_for_path(file_path) do
      {:ok, buffer} ->
        {:ok, buffer}

      :not_found ->
        Commands.start_buffer(file_path, state.interaction.options_server,
          events_registry: state.extension_surfaces.events_registry,
          allow_missing: true
        )
    end
  end

  # The user asked for this text, so its file takes the screen.
  @spec show_in_front(state(), pid(), String.t()) :: state()
  defp show_in_front(state, buffer, file_path) do
    case BufferRegistry.file_tab_for_path_in_active_workspace(state, file_path) do
      %{id: tab_id} -> MingaEditor.TabWorkflow.switch(state, tab_id)
      nil -> BufferRegistry.register_buffer(state, buffer, file_path)
    end
  end

  # A recovered file takes the screen only when nothing else has it.
  # After a restored session the focused file stays focused.
  @spec show_recovered(state(), pid(), String.t()) :: state()
  defp show_recovered(state, buffer, file_path) do
    cond do
      BufferRegistry.buffer_tracked?(state, buffer) ->
        state

      is_nil(state.workspace.buffers.active) ->
        BufferRegistry.register_buffer(state, buffer, file_path)

      true ->
        BufferRegistry.register_buffer_background(state, buffer, file_path)
    end
  end
end
