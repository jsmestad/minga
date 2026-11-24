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
    A space was already sent as an ordinary key. Delete it from the
    surface that took it, then enter leader mode.

  `note_key/3` runs at key ingress and records where each such space
  goes (`CUA.SpaceTarget`), so the retract deletes it from that surface
  only. A file buffer hidden behind Agent chat or a focused bottom panel
  never loses a character, and a space typed into an overlay stays there
  with the next key.

  The Swift side handles all timing and keyUp tracking. The BEAM side
  is stateless: it receives gui_actions and reacts.

  ## When active

  Only active when `editing_model: :cua` and `space_leader: :chord`.
  In vim mode, SPC is already a pure leader key in normal mode.
  """

  alias Minga.Buffer
  alias MingaEditor.Commands
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.Input.CUA.SpaceTarget
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
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
    held = held_space(state)
    state = hold_space(state, nil)

    if active?(state) do
      retract_into_leader(state, held, codepoint, modifiers)
    else
      # Space leader not active. The grace timer already fired and sent
      # the space, so it's in the buffer. Just dispatch the key normally.
      dispatch_key_normally(state, codepoint, modifiers)
    end
  end

  @doc """
  Records where a frontend-sent SPC goes, before the key is routed.

  The macOS frontend sends a held SPC as an ordinary key and the next key as a `space_leader_retract`. Recording the target here lets `handle_retract/3` remove the space from the surface that took it. Every other key clears the record, so a retract never acts on an older space. The terminal frontend keeps its own window in `CUA.TUISpaceLeader`.
  """
  @spec note_key(EditorState.t(), non_neg_integer(), non_neg_integer()) :: EditorState.t()
  def note_key(%EditorState{frontend: %{backend: backend}} = state, ?\s, 0)
      when backend != :tui do
    if active?(state), do: hold_space(state, SpaceTarget.resolve(state)), else: state
  end

  def note_key(%EditorState{} = state, _codepoint, _modifiers), do: hold_space(state, nil)

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

  # A leader key retracts the space from the surface that took it and starts the
  # leader. With no recorded space, or a space an overlay took as text, the key
  # goes to the focused surface like any other.
  @spec retract_into_leader(
          EditorState.t(),
          SpaceTarget.t() | nil,
          non_neg_integer(),
          non_neg_integer()
        ) :: EditorState.t()
  defp retract_into_leader(state, held, codepoint, modifiers) when held in [nil, :overlay],
    do: dispatch_key_normally(state, codepoint, modifiers)

  defp retract_into_leader(state, held, codepoint, modifiers) do
    case lookup_leader(leader_trie(state), codepoint, modifiers) do
      {:match, node} ->
        state
        |> retract_space(held)
        |> enter_leader(node)

      :no_match ->
        # Key doesn't match. Leave the space, process key normally.
        dispatch_key_normally(state, codepoint, modifiers)
    end
  end

  @spec retract_space(EditorState.t(), SpaceTarget.t()) :: EditorState.t()
  defp retract_space(state, {:buffer, buf}) do
    Buffer.break_undo_coalescing(buf)
    Buffer.delete_before(buf)
    Buffer.break_undo_coalescing(buf)
    state
  catch
    :exit, _ -> state
  end

  # Only the composer that took the space loses it; a composer swapped in since
  # then is left alone.
  defp retract_space(
         %{workspace: %{agent_ui: %{panel: %{prompt_buffer: prompt}}}} = state,
         {:composer, prompt}
       )
       when is_pid(prompt),
       do: AgentCommands.input_backspace(state)

  defp retract_space(state, _no_text_or_stale_composer), do: state

  @spec held_space(EditorState.t()) :: SpaceTarget.t() | nil
  defp held_space(%EditorState{} = state) do
    case Runtime.state(state.shell_runtime) do
      %TraditionalState{} = shell_state -> TraditionalState.held_space(shell_state)
      _extension_state -> nil
    end
  end

  @spec hold_space(EditorState.t(), SpaceTarget.t() | nil) :: EditorState.t()
  defp hold_space(%EditorState{} = state, target) do
    case Runtime.state(state.shell_runtime) do
      %TraditionalState{} = shell_state ->
        if TraditionalState.held_space(shell_state) == target do
          state
        else
          shell_state = TraditionalState.hold_space(shell_state, target)

          %{
            state
            | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)
          }
        end

      _extension_state ->
        state
    end
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
