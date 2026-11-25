defmodule MingaEditor.Commands.Launchpad do
  @moduledoc """
  Activation semantics for the zero-buffers launchpad (#2689).

  Both frontends funnel here: the TUI via `MingaEditor.Input.EmptyState`
  (Enter/jump keys) and the GUI via the `empty_state_activate` gui_action
  (clicks), so activation behavior cannot drift between them.
  """

  use MingaEditor.Commands.Provider

  alias Minga.Buffer
  alias MingaEditor.Commands
  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.Handlers.BufferRegistry
  alias MingaEditor.Handlers.SessionRestore
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Launchpad
  alias MingaEditor.State.Windows
  alias MingaEditor.WindowTree

  @type state :: EditorState.t()

  command(:resume_session, "Resume the previous session", requires_buffer: false)

  command(:session_start_fresh, "Start fresh instead of the restored session",
    requires_buffer: false
  )

  @spec execute(state(), :resume_session | :session_start_fresh) :: state()
  def execute(state, :resume_session) do
    SessionRestore.restore_session(state)
  end

  # Closes every file without unsaved edits, one at a time, after dropping the restored splits.
  # Unsaved files stay open, and Minga's unreviewed changes live in the review, so nothing is lost.
  def execute(state, :session_start_fresh) do
    state = close_splits(state)
    budget = length(BufferRegistry.buffer_inventory(state))
    state = close_clean_files(state, budget)

    unsaved =
      state
      |> BufferRegistry.buffer_inventory()
      |> Enum.flat_map(&file_buffer/1)
      |> Enum.count(fn {_pid, _path, dirty?} -> dirty? end)

    kept_notice(state, unsaved)
  end

  @doc """
  Activates a launchpad item by id.

  No-op when the workspace is not in the empty state or the id is unknown,
  so a stale GUI click echo cannot corrupt state.
  """
  @spec activate(state(), String.t()) :: state()
  def activate(%{workspace: %{launchpad: %Launchpad{} = lp}} = state, item_id) do
    do_activate(state, lp, item_id)
  end

  def activate(state, _item_id), do: state

  @doc """
  Creates an `Untitled-N` buffer and enters insert mode.

  The one-keystroke vim materialization (`i`/`a`/`o`/`O`) from the empty
  state: buffer creation flips the window back to buffer content and clears
  the launchpad through `MingaEditor.Session.State.activate_buffer/2`.
  """
  @spec materialize_and_insert(state()) :: state()
  def materialize_and_insert(state) do
    state = Commands.execute(state, :new_buffer)

    if state.workspace.buffers.active do
      %{state | workspace: MingaEditor.Session.State.transition_mode(state.workspace, :insert)}
    else
      state
    end
  end

  # The restored splits go first, keeping the focused window, so each file closes with its own tab.
  @spec close_splits(state()) :: state()
  defp close_splits(%{workspace: %{windows: %{tree: nil}}} = state), do: state

  defp close_splits(state) do
    windows = state.workspace.windows

    windows =
      windows.tree
      |> WindowTree.leaves()
      |> List.delete(windows.active)
      |> Enum.reduce(windows, fn id, acc ->
        case Windows.remove_window(acc, id) do
          {:ok, removed} -> removed
          :error -> acc
        end
      end)

    workspace = MingaEditor.Session.State.set_windows(state.workspace, windows)
    MingaEditor.Layout.fit_windows(%{state | workspace: workspace})
  end

  # Each pass shows one clean file and kills it, so the budget (the files open at the start) bounds the loop.
  @spec close_clean_files(state(), non_neg_integer()) :: state()
  defp close_clean_files(state, 0), do: state

  defp close_clean_files(state, budget) do
    clean =
      state
      |> BufferRegistry.buffer_inventory()
      |> Enum.flat_map(&file_buffer/1)
      |> Enum.find(fn {_pid, _path, dirty?} -> not dirty? end)

    case clean do
      nil ->
        state

      {pid, path, _dirty?} ->
        state |> show_buffer(pid, path) |> kill_shown(pid) |> close_clean_files(budget - 1)
    end
  end

  @spec show_buffer(state(), pid(), String.t()) :: state()
  defp show_buffer(%{workspace: %{buffers: %{active: pid}}} = state, pid, _path), do: state

  defp show_buffer(state, _pid, path) do
    case BufferRegistry.open_or_activate_path(state, path, existing_target: :tab) do
      {:ok, state, _pid, _status} -> state
      {:error, _reason} -> state
    end
  end

  @spec kill_shown(state(), pid()) :: state()
  defp kill_shown(%{workspace: %{buffers: %{active: pid}}} = state, pid),
    do: BufferManagement.execute(state, :kill_buffer)

  defp kill_shown(state, _pid), do: state

  @spec file_buffer(pid()) :: [{pid(), String.t(), boolean()}]
  defp file_buffer(pid) do
    case Buffer.file_path(pid) do
      path when is_binary(path) -> [{pid, path, Buffer.dirty?(pid)}]
      nil -> []
    end
  catch
    :exit, _ -> []
  end

  @spec kept_notice(state(), non_neg_integer()) :: state()
  defp kept_notice(state, 0), do: state
  defp kept_notice(state, 1), do: NoticeWorkflow.publish(state, "Kept 1 unsaved file open")
  defp kept_notice(state, n), do: NoticeWorkflow.publish(state, "Kept #{n} unsaved files open")

  @spec do_activate(state(), Launchpad.t(), String.t()) :: state()
  defp do_activate(state, _lp, "resume") do
    execute(state, :resume_session)
  end

  defp do_activate(state, _lp, "action-find-file"), do: Commands.execute(state, :find_file)
  defp do_activate(state, _lp, "action-file-tree"), do: Commands.execute(state, :toggle_file_tree)
  defp do_activate(state, _lp, "action-palette"), do: Commands.execute(state, :command_palette)
  defp do_activate(state, _lp, "action-tutor"), do: Commands.execute(state, :tutor)

  defp do_activate(state, lp, "recent-" <> _ = item_id) do
    case Launchpad.recent_path(lp, item_id) do
      nil -> state
      path -> Commands.execute(state, {:execute_ex_command, {:edit, path}})
    end
  end

  defp do_activate(state, _lp, _unknown), do: state
end
