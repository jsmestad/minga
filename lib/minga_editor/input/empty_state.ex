defmodule MingaEditor.Input.EmptyState do
  @moduledoc """
  Input handler for the zero-buffers launchpad (#2689).

  Claims only focus movement (`j`/`k`/arrows/`gg`/`G`), Enter, and the jump
  keys (`r`, `1`-`5`); everything else passes through so modal muscle
  memory survives: leader chords run mid-sequence, `i`/`a`/`o`/`O`
  materialize an `Untitled-N` buffer in insert mode, `:` opens the
  minibuffer, and `q` is deliberately not claimed.

  Modeled on `MingaEditor.Input.AgentPanel`'s claim-and-delegate routing.
  Activation semantics live in `MingaEditor.Commands.Launchpad` so the GUI
  click path behaves identically.
  """

  @behaviour MingaEditor.Input.Handler

  alias MingaEditor.Commands.Launchpad, as: LaunchpadCommands
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Launchpad

  @arrow_up 0xF700
  @arrow_down 0xF701

  # Keys that materialize an Untitled buffer and enter insert mode.
  @insert_entry_keys [?i, ?a, ?o, ?O]

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(%{workspace: %{launchpad: %Launchpad{} = lp}} = state, cp, mods) do
    # Engage only in plain normal mode: command-line (:), leader sequences,
    # and any other mode belong to the handlers below (ModeFSM).
    if Minga.Editing.mode(state) == :normal and not Minga.Editing.in_leader?(state) do
      route_key(state, lp, cp, mods)
    else
      {:passthrough, state}
    end
  end

  def handle_key(state, _cp, _mods), do: {:passthrough, state}

  @spec route_key(EditorState.t(), Launchpad.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  defp route_key(state, lp, cp, 0) when cp in [?j, @arrow_down] do
    {:handled,
     put_launchpad(state, lp |> Launchpad.clear_pending_g() |> Launchpad.move_focus(:next))}
  end

  defp route_key(state, lp, cp, 0) when cp in [?k, @arrow_up] do
    {:handled,
     put_launchpad(state, lp |> Launchpad.clear_pending_g() |> Launchpad.move_focus(:prev))}
  end

  defp route_key(state, lp, ?G, 0) do
    {:handled,
     put_launchpad(state, lp |> Launchpad.clear_pending_g() |> Launchpad.move_focus(:last))}
  end

  defp route_key(state, lp, ?g, 0) do
    {:handled, put_launchpad(state, Launchpad.press_g(lp))}
  end

  # Enter activates the focused item.
  defp route_key(state, %Launchpad{focused_id: focused}, 13, 0) when is_binary(focused) do
    {:handled, LaunchpadCommands.activate(state, focused)}
  end

  # `r` jump-activates resume when a session exists.
  defp route_key(state, %Launchpad{session_file_count: count}, ?r, 0) when count > 0 do
    {:handled, LaunchpadCommands.activate(state, Launchpad.resume_id())}
  end

  # `1`-`5` jump-activate recent files that exist.
  defp route_key(state, %Launchpad{} = lp, cp, 0) when cp in ?1..?5 do
    item_id = Launchpad.recent_id(cp - ?0)

    if Launchpad.recent_path(lp, item_id) do
      {:handled, LaunchpadCommands.activate(state, item_id)}
    else
      {:passthrough, disarm(state, lp)}
    end
  end

  # `i`/`a`/`o`/`O` materialize an Untitled buffer in insert mode.
  defp route_key(state, _lp, cp, 0) when cp in @insert_entry_keys do
    {:handled, LaunchpadCommands.materialize_and_insert(state)}
  end

  # Everything else (including `q`, `:`, and modified keys) passes through
  # to normal-mode dispatch; a pending `gg` chord is disarmed.
  defp route_key(state, lp, _cp, _mods), do: {:passthrough, disarm(state, lp)}

  @spec disarm(EditorState.t(), Launchpad.t()) :: EditorState.t()
  defp disarm(state, %Launchpad{pending_g?: true} = lp) do
    put_launchpad(state, Launchpad.clear_pending_g(lp))
  end

  defp disarm(state, _lp), do: state

  @spec put_launchpad(EditorState.t(), Launchpad.t()) :: EditorState.t()
  defp put_launchpad(state, lp) do
    %{state | workspace: MingaEditor.Session.State.set_launchpad(state.workspace, lp)}
  end
end
