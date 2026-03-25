defmodule Minga.Input.CUA.SpaceLeader do
  @moduledoc """
  Handles SPC-as-leader gui_actions from native GUI frontends.

  In CUA mode with `space_leader: :chord`, the Swift frontend detects
  key-chord gestures (SPC held + another key) and sends gui_actions
  to the BEAM:

  - `space_leader_chord`: clean chord within the 30ms grace period.
    No space was sent to the BEAM. Enter leader mode directly.
  - `space_leader_retract`: fallback chord after the grace period.
    A space was already sent. Delete it, then enter leader mode.

  The Swift side handles all timing and keyUp tracking. The BEAM side
  is stateless: it receives gui_actions and reacts.

  ## When active

  Only active when `editing_model: :cua` and `space_leader: :chord`.
  In vim mode, SPC is already a pure leader key in normal mode.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands
  alias Minga.Editor.Editing
  alias Minga.Editor.State, as: EditorState
  alias Minga.Keymap.Active, as: KeymapActive

  @doc """
  Handles a `space_leader_chord` gui_action.

  Clean chord: SPC was never sent to the BEAM. Look up the key in the
  leader trie and enter leader/which-key mode if it matches.
  """
  @spec handle_chord(EditorState.t(), non_neg_integer(), non_neg_integer()) :: EditorState.t()
  def handle_chord(state, codepoint, modifiers) do
    if active?() do
      trie = leader_trie()

      case lookup_leader(trie, codepoint, modifiers) do
        {:match, node} ->
          enter_leader(state, node)

        :no_match ->
          # Key doesn't match a leader prefix. Insert the space that the
          # frontend withheld, then process the key normally.
          state = insert_space(state)
          dispatch_key_normally(state, codepoint, modifiers)
      end
    else
      state
    end
  end

  @doc """
  Handles a `space_leader_retract` gui_action.

  Fallback chord: a space was already sent (grace timer fired on Swift
  side). Delete the space, then enter leader mode.
  """
  @spec handle_retract(EditorState.t(), non_neg_integer(), non_neg_integer()) :: EditorState.t()
  def handle_retract(state, codepoint, modifiers) do
    if active?() do
      trie = leader_trie()

      case lookup_leader(trie, codepoint, modifiers) do
        {:match, node} ->
          state = retract_space(state)
          enter_leader(state, node)

        :no_match ->
          # Key doesn't match. Leave the space, process key normally.
          dispatch_key_normally(state, codepoint, modifiers)
      end
    else
      state
    end
  end

  @doc """
  Returns true when the space leader feature is active.
  """
  @spec active?() :: boolean()
  def active? do
    Editing.active_model() == Minga.EditingModel.CUA and
      Minga.Config.Options.get(:space_leader) == :chord
  catch
    :exit, _ -> false
  end

  # ── Private ──────────────────────────────────────────────────────────────

  @spec enter_leader(EditorState.t(), Minga.Keymap.Bindings.node_t()) :: EditorState.t()
  defp enter_leader(state, node) do
    if node.command != nil do
      execute_command(state, node.command)
    else
      result = Commands.execute(state, {:leader_start, node})

      case result do
        {s, {:whichkey_update, wk}} -> %{s | whichkey: wk}
        s -> s
      end
    end
  end

  @spec insert_space(EditorState.t()) :: EditorState.t()
  defp insert_space(state) do
    buf = state.workspace.buffers.active
    if is_pid(buf), do: BufferServer.insert_char(buf, " ")
    state
  catch
    :exit, _ -> state
  end

  @spec retract_space(EditorState.t()) :: EditorState.t()
  defp retract_space(state) do
    buf = state.workspace.buffers.active

    if is_pid(buf) do
      BufferServer.break_undo_coalescing(buf)
      BufferServer.delete_before(buf)
      BufferServer.break_undo_coalescing(buf)
    end

    state
  catch
    :exit, _ -> state
  end

  @spec dispatch_key_normally(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()
  defp dispatch_key_normally(state, codepoint, modifiers) do
    Minga.Input.Router.dispatch(state, codepoint, modifiers)
  end

  @spec execute_command(EditorState.t(), atom() | tuple()) :: EditorState.t()
  defp execute_command(state, cmd) do
    case Commands.execute(state, cmd) do
      {s, {:whichkey_update, wk}} -> %{s | whichkey: wk}
      s when is_map(s) -> s
      {s, _action} -> s
    end
  end

  @spec leader_trie() :: Minga.Keymap.Bindings.node_t()
  defp leader_trie do
    KeymapActive.leader_trie()
  catch
    :exit, _ -> Minga.Keymap.Bindings.new()
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
