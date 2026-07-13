defmodule MingaEditor.Commands.Launchpad do
  @moduledoc """
  Activation semantics for the zero-buffers launchpad (#2689).

  Both frontends funnel here: the TUI via `MingaEditor.Input.EmptyState`
  (Enter/jump keys) and the GUI via the `empty_state_activate` gui_action
  (clicks), so activation behavior cannot drift between them.
  """

  use MingaEditor.Commands.Provider

  alias MingaEditor.Commands
  alias MingaEditor.Handlers.SessionRestore
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Launchpad

  @type state :: EditorState.t()

  command(:resume_session, "Resume the previous session", requires_buffer: false)

  @spec execute(state(), :resume_session) :: state()
  def execute(state, :resume_session) do
    SessionRestore.restore_session(state)
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
      EditorState.transition_mode(state, :insert)
    else
      state
    end
  end

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
