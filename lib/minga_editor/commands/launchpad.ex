defmodule MingaEditor.Commands.Launchpad do
  @moduledoc """
  Commands and activation semantics for the project home, `*home*` (#4056).

  Both frontends funnel here: keys via `MingaEditor.Input.EmptyState` (`↩`, `1` to `9`) and clicks via the `empty_state_activate` gui_action, so activation behaviour cannot drift between them. `SPC p h` shows the home from anywhere, and `SPC q n` starts fresh instead of the restored session.
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
  command(:project_home, "Project home", requires_buffer: false)

  command(:session_start_fresh, "Start fresh instead of the restored session",
    requires_buffer: false
  )

  command(:unsaved_text, "List unsaved text kept after a crash, to recover or discard it",
    requires_buffer: false
  )

  @spec execute(state(), :resume_session | :project_home | :session_start_fresh | :unsaved_text) ::
          state()
  def execute(state, :unsaved_text) do
    MingaEditor.PickerUI.open(state, MingaEditor.UI.Picker.UnsavedTextSource, %{
      swap_opts: MingaEditor.State.Session.swap_opts(state.session)
    })
  end

  def execute(state, :resume_session) do
    SessionRestore.restore_session(state)
  end

  # The active tab steps aside with its own snapshot (splits and conversations included); opening it again restores it.
  def execute(state, :project_home), do: MingaEditor.TabWorkflow.leave_to_home(state)

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

    state
    |> MingaEditor.TabWorkflow.leave_to_home()
    |> kept_notice(unsaved)
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
  defp do_activate(state, home, "recent-" <> _ = item_id) do
    case Launchpad.recent_path(home, item_id) do
      nil -> state
      path -> Commands.execute(state, {:execute_ex_command, {:edit, path}})
    end
  end

  defp do_activate(state, home, "project-" <> _ = item_id) do
    case Launchpad.project_root(home, item_id) do
      nil -> state
      root -> open_project(state, root)
    end
  end

  defp do_activate(state, _home, "task-" <> _ = item_id) do
    case Launchpad.task_workspace(item_id) do
      nil -> state
      workspace_id -> Commands.execute(state, {:workspace_goto, workspace_id})
    end
  end

  defp do_activate(state, home, "action-" <> _ = item_id) do
    case Launchpad.action_command(home, item_id) do
      nil -> state
      command -> Commands.execute(state, command)
    end
  end

  defp do_activate(state, _home, _unknown), do: state

  # Opening a recent project makes it the root, then picks up its saved session; without one its home shows.
  @spec open_project(state(), String.t()) :: state()
  defp open_project(state, root) do
    case Minga.Project.Root.directory(root) do
      {:ok, dir} -> activate_project(state, dir)
      {:error, _reason} -> NoticeWorkflow.publish(state, "Cannot open #{root}")
    end
  end

  @spec activate_project(state(), Minga.Project.Root.t()) :: state()
  defp activate_project(state, dir) do
    case Minga.Project.activate(Minga.Project, dir) do
      {:ok, %{root: installed}} ->
        state = MingaEditor.FileTree.Freshness.update_project_root(state, installed.path)
        before = BufferRegistry.buffer_inventory(state)

        state
        |> SessionRestore.restore_session()
        |> show_home_unless_restored(before)

      {:error, reason} ->
        NoticeWorkflow.publish(state, "Cannot open #{dir.path}: #{inspect(reason)}")
    end
  catch
    :exit, _ -> NoticeWorkflow.publish(state, "Cannot open #{dir.path}")
  end

  # Without a saved session the new project's own home replaces the old one.
  @spec show_home_unless_restored(state(), [pid()]) :: state()
  defp show_home_unless_restored(state, before) do
    if BufferRegistry.buffer_inventory(state) == before,
      do: MingaEditor.TabWorkflow.leave_to_home(state),
      else: state
  end
end
