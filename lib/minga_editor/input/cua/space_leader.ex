defmodule MingaEditor.Input.CUA.SpaceLeader do
  @moduledoc """
  Handles SPC-as-leader gui_actions from native GUI frontends.

  In CUA mode with `space_leader: :chord`, the Swift frontend detects
  key-chord gestures (SPC held + another key) and sends gui_actions
  to the BEAM:

  - `space_leader_chord`: clean chord within the 30ms grace period.
    No space was sent to the BEAM. Enter leader mode directly. When the
    space leader is inactive or the key matches no leader binding, replay
    the withheld space and the key through the input router.
  - `space_leader_retract`: fallback chord after the grace period.
    A space was already sent. Delete it, then enter leader mode.

  The Swift side handles all timing and keyUp tracking. The BEAM side
  is stateless: it receives gui_actions and reacts.

  ## When active

  Only active when `editing_model: :cua` and `space_leader: :chord`.
  In vim mode, SPC is already a pure leader key in normal mode.
  """

  alias Minga.Buffer
  alias MingaEditor.Commands
  alias MingaEditor.State, as: EditorState
  alias Minga.Keymap

  @doc """
  Handles a `space_leader_chord` gui_action.

  Clean chord: SPC was never sent to the BEAM. Look up the key in the
  leader trie and enter leader/which-key mode if it matches.
  """
  @spec handle_chord(EditorState.t(), non_neg_integer(), non_neg_integer()) :: EditorState.t()
  def handle_chord(state, codepoint, modifiers) do
    if active?(state) do
      trie = leader_trie(state)

      case lookup_leader(trie, codepoint, modifiers) do
        {:match, node} ->
          enter_leader(state, node)

        :no_match ->
          # Key doesn't match a leader prefix. Replay the withheld space
          # and the key as two ordinary keystrokes.
          replay_withheld_space(state, codepoint, modifiers)
      end
    else
      # Space leader not active (Vim mode, or CUA without :chord). The
      # Swift frontend withheld the space and sent the next key as a chord
      # gui_action. Replay both as ordinary keystrokes so the focused
      # surface decides what SPC means: Vim Normal starts the leader, a
      # composer or picker receives a space.
      replay_withheld_space(state, codepoint, modifiers)
    end
  end

  @doc """
  Handles a `space_leader_retract` gui_action.

  Fallback chord: a space was already sent (grace timer fired on Swift
  side). Delete the space, then enter leader mode.
  """
  @spec handle_retract(EditorState.t(), non_neg_integer(), non_neg_integer()) :: EditorState.t()
  def handle_retract(state, codepoint, modifiers) do
    if active?(state) do
      trie = leader_trie(state)

      case lookup_leader(trie, codepoint, modifiers) do
        {:match, node} ->
          state = retract_space(state)
          enter_leader(state, node)

        :no_match ->
          # Key doesn't match. Leave the space, process key normally.
          dispatch_key_normally(state, codepoint, modifiers)
      end
    else
      # Space leader not active. The grace timer already fired and sent
      # the space, so it's in the buffer. Just dispatch the key normally.
      dispatch_key_normally(state, codepoint, modifiers)
    end
  end

  @doc """
  Returns true when the space leader feature is active.
  """
  @spec active?(map()) :: boolean()
  def active?(state) do
    Minga.Editing.active_model(state) == Minga.Editing.Model.CUA and
      Minga.Config.get(:space_leader) == :chord
  catch
    :exit, _ -> false
  end

  # ── Private ──────────────────────────────────────────────────────────────

  @spec enter_leader(EditorState.t(), Minga.Keymap.Bindings.node_t()) :: EditorState.t()
  defp enter_leader(state, node) do
    if node.command != nil do
      execute_command(state, node.command)
    else
      Commands.execute(state, {:leader_start, node})
    end
  end

  # The withheld space goes through the input router, never straight into the
  # active buffer: only the focused surface knows whether SPC is text or a leader.
  @spec replay_withheld_space(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()
  defp replay_withheld_space(state, codepoint, modifiers) do
    state
    |> dispatch_key_normally(?\s, 0)
    |> dispatch_key_normally(codepoint, modifiers)
  end

  @spec retract_space(EditorState.t()) :: EditorState.t()
  defp retract_space(state) do
    buf = state.workspace.buffers.active

    if is_pid(buf) do
      Buffer.break_undo_coalescing(buf)
      Buffer.delete_before(buf)
      Buffer.break_undo_coalescing(buf)
    end

    state
  catch
    :exit, _ -> state
  end

  @spec dispatch_key_normally(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()
  defp dispatch_key_normally(state, codepoint, modifiers) do
    MingaEditor.Input.Router.route_key(state, codepoint, modifiers)
  end

  @spec execute_command(EditorState.t(), atom() | tuple()) :: EditorState.t()
  defp execute_command(state, cmd) do
    case Commands.execute(state, cmd) do
      s when is_map(s) -> s
      {s, _action} -> s
    end
  end

  @spec leader_trie(EditorState.t()) :: Minga.Keymap.Bindings.node_t()
  defp leader_trie(state) do
    Keymap.leader_trie(state.interaction.keymap_server)
  catch
    :exit, _ ->
      Minga.Log.warning(:config, "leader_trie unavailable; SPC bindings disabled this frame")
      Minga.Keymap.Bindings.new()
  end

  @spec lookup_leader(Minga.Keymap.Bindings.node_t(), non_neg_integer(), non_neg_integer()) ::
          {:match, Minga.Keymap.Bindings.node_t()} | :no_match
  defp lookup_leader(trie, codepoint, modifiers) do
    key = {codepoint, modifiers}

    case Map.get(trie.children, key) do
      nil -> :no_match
      node -> {:match, node}
    end
  end
end
