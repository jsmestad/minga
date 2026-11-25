defmodule MingaEditor.Input.EmptyState do
  @moduledoc """
  Input handler for the project home, `*home*` (#4056).

  The home is a resting view, not a buffer you type into. While it fills the active window in Normal mode this handler claims focus movement (`j`/`k`/arrows/`gg`/`G`), `↩`, and the number keys `1` to `9`, which open a recent file or a recent project. `q` does nothing: there is nothing to close. `i`/`a`/`o`/`O` start an `Untitled` buffer in Insert mode. Every other printable key is claimed and ignored, so a key never edits a buffer the window is not showing. The leader, `:` and modified keys pass through, so `SPC` commands, the command line and window keys keep working.

  Activation semantics live in `MingaEditor.Commands.Launchpad` so the GUI click path behaves identically.
  """

  @behaviour MingaEditor.Input.Handler

  alias MingaEditor.Commands.Launchpad, as: LaunchpadCommands
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Launchpad

  @arrow_up 0xF700
  @arrow_down 0xF701
  @enter 13

  # Keys that start an Untitled buffer in Insert mode.
  @insert_entry_keys [?i, ?a, ?o, ?O]

  # Keys that keep their meaning on the home: the leader and the command line.
  @passthrough_keys [?\s, ?:]

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(%{workspace: %{launchpad: %Launchpad{} = home}} = state, cp, mods) do
    # Only on the home in plain Normal mode.
    # The command line, leader sequences and other modes belong to later handlers.
    if showing_home?(state) and Minga.Editing.mode(state) == :normal and
         not Minga.Editing.in_leader?(state) do
      route_key(state, home, cp, mods)
    else
      {:passthrough, state}
    end
  end

  def handle_key(state, _cp, _mods), do: {:passthrough, state}

  @doc "True when the active window shows the home."
  @spec showing_home?(EditorState.t()) :: boolean()
  def showing_home?(%{workspace: workspace}) do
    match?(
      %{content: {:empty, :semantic}},
      MingaEditor.Session.State.active_window_struct(workspace)
    )
  end

  @spec route_key(EditorState.t(), Launchpad.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  defp route_key(state, home, cp, 0) when cp in [?j, @arrow_down],
    do: {:handled, move(state, home, :next)}

  defp route_key(state, home, cp, 0) when cp in [?k, @arrow_up],
    do: {:handled, move(state, home, :prev)}

  defp route_key(state, home, ?G, 0), do: {:handled, move(state, home, :last)}

  defp route_key(state, home, ?g, 0) do
    {:handled, put_home(state, Launchpad.press_g(home, task_ids(state, home)))}
  end

  defp route_key(state, %Launchpad{focused_id: focused} = home, @enter, 0)
       when is_binary(focused) do
    {:handled, LaunchpadCommands.activate(disarm(state, home), focused)}
  end

  # `1` to `9` open the numbered row, when there is one.
  defp route_key(state, home, cp, 0) when cp in ?1..?9 do
    state = disarm(state, home)

    case Launchpad.numbered_id(home, cp - ?0) do
      nil -> {:handled, state}
      id -> {:handled, LaunchpadCommands.activate(state, id)}
    end
  end

  defp route_key(state, home, cp, 0) when cp in @insert_entry_keys do
    {:handled, LaunchpadCommands.materialize_and_insert(disarm(state, home))}
  end

  defp route_key(state, home, cp, 0) when cp in @passthrough_keys,
    do: {:passthrough, disarm(state, home)}

  # Any other printable key, `q` included, does nothing on a resting view.
  defp route_key(state, home, cp, 0) when cp in 33..126, do: {:handled, disarm(state, home)}

  defp route_key(state, home, _cp, _mods), do: {:passthrough, disarm(state, home)}

  @spec move(EditorState.t(), Launchpad.t(), :next | :prev | :first | :last) :: EditorState.t()
  defp move(state, home, direction) do
    home =
      home
      |> Launchpad.clear_pending_g()
      |> Launchpad.move_focus(direction, task_ids(state, home))

    put_home(state, home)
  end

  @spec task_ids(EditorState.t(), Launchpad.t()) :: [String.t()]
  defp task_ids(state, home),
    do: Launchpad.task_ids(state.agent_connection.tasks, state.shell_runtime.state.tab_bar, home)

  @spec disarm(EditorState.t(), Launchpad.t()) :: EditorState.t()
  defp disarm(state, %Launchpad{pending_g?: true} = home),
    do: put_home(state, Launchpad.clear_pending_g(home))

  defp disarm(state, _home), do: state

  @spec put_home(EditorState.t(), Launchpad.t()) :: EditorState.t()
  defp put_home(state, home) do
    %{state | workspace: MingaEditor.Session.State.set_launchpad(state.workspace, home)}
  end
end
