defmodule Minga.Input.SpaceLeader do
  @moduledoc """
  Input handler for SPC-as-leader in CUA mode.

  In CUA mode with `space_leader: :chord`, tapping SPC types a space
  while holding SPC and pressing another key opens the which-key command
  layer. This handler sits above CUADispatch in the surface handler stack
  and intercepts SPC key presses.

  ## How it works

  1. SPC arrives: insert the space immediately (no delay), set
     `space_pending` flag, start a timer.
  2. Next key arrives while `space_pending` is true: check the leader
     trie. If the key matches a prefix, retract the space (delete
     without undo entry) and enter leader/which-key mode. If no match,
     clear `space_pending` and let the key through normally.
  3. Timer fires: clear `space_pending`. The space was just a space.

  The timer duration is configurable via `space_leader_timeout` (default
  200ms). This is well below normal typing speed for word boundaries
  (~300ms+) but catches the rare case where a leader key happens to
  match the first letter of the next word.

  ## State

  Space leader state lives on EditorState as `space_leader_pending`
  (boolean) and `space_leader_timer` (timer ref or nil). These are
  global fields, not per-tab, because the leader key is a UI-level
  concern shared across all tabs.

  ## When active

  Only active when `editing_model: :cua` and `space_leader: :chord`.
  In vim mode, SPC is already a pure leader key in normal mode.
  """

  @behaviour Minga.Input.Handler

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands
  alias Minga.Editor.Editing
  alias Minga.Editor.State, as: EditorState
  alias Minga.Keymap.Active, as: KeymapActive

  @space 0x20

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Input.Handler.result()
  def handle_key(state, @space, 0) do
    # Plain SPC with no modifiers: insert space and start pending
    if active?(state) and not state.space_leader_pending do
      state = insert_space_and_start_pending(state)
      {:handled, state}
    else
      {:passthrough, state}
    end
  end

  def handle_key(state, codepoint, modifiers) do
    if state.space_leader_pending do
      handle_pending_key(state, codepoint, modifiers)
    else
      {:passthrough, state}
    end
  end

  @spec handle_pending_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Input.Handler.result()
  defp handle_pending_key(state, codepoint, modifiers) do
    state = cancel_timer(state)
    trie = leader_trie()

    case lookup_leader(trie, codepoint, modifiers) do
      {:match, node} ->
        enter_leader_from_space(state, node)

      :no_match ->
        {:passthrough, %{state | space_leader_pending: false}}
    end
  end

  @spec enter_leader_from_space(EditorState.t(), Minga.Keymap.Bindings.node_t()) ::
          Minga.Input.Handler.result()
  defp enter_leader_from_space(state, node) do
    state = retract_space(state)
    state = %{state | space_leader_pending: false}

    if node.command != nil do
      {:handled, execute_leader_command(state, node.command)}
    else
      result = Commands.execute(state, {:leader_start, node})

      state =
        case result do
          {s, {:whichkey_update, wk}} -> %{s | whichkey: wk}
          s -> s
        end

      {:handled, state}
    end
  end

  # ── Public API for timer handling ────────────────────────────────────────

  @doc """
  Handles the space leader timeout. Called from Editor.handle_info.

  Clears the pending flag. The space that was inserted stays (it was real).
  """
  @spec handle_timeout(EditorState.t(), reference()) :: EditorState.t()
  def handle_timeout(%{space_leader_timer: ref} = state, ref) do
    %{state | space_leader_pending: false, space_leader_timer: nil}
  end

  def handle_timeout(state, _stale_ref), do: state

  @doc """
  Returns true when the space leader feature is active for the current config.
  """
  @spec active?(EditorState.t()) :: boolean()
  def active?(_state) do
    Editing.active_model() == Minga.EditingModel.CUA and
      Minga.Config.Options.get(:space_leader) == :chord
  catch
    :exit, _ -> false
  end

  # ── Private ──────────────────────────────────────────────────────────────

  @spec insert_space_and_start_pending(EditorState.t()) :: EditorState.t()
  defp insert_space_and_start_pending(state) do
    # Insert the space immediately (no delay for the user)
    buf = state.buffers.active

    if is_pid(buf) do
      BufferServer.insert_char(buf, " ")
    end

    # Start the timeout timer
    timeout_ms = Minga.Config.Options.get(:space_leader_timeout)
    ref = make_ref()
    Process.send_after(self(), {:space_leader_timeout, ref}, timeout_ms)

    %{state | space_leader_pending: true, space_leader_timer: ref}
  catch
    :exit, _ ->
      %{state | space_leader_pending: true, space_leader_timer: nil}
  end

  @spec retract_space(EditorState.t()) :: EditorState.t()
  defp retract_space(state) do
    buf = state.buffers.active

    if is_pid(buf) do
      # Delete the space we just inserted. Use delete_before which removes
      # the character before the cursor. We break undo coalescing first so
      # the space insertion and deletion cancel out as a no-op in the undo
      # history (the space insert was coalesced with prior typing, breaking
      # coalescing before delete means the delete starts a new group that
      # effectively undoes just the space).
      BufferServer.break_undo_coalescing(buf)
      BufferServer.delete_before(buf)
      BufferServer.break_undo_coalescing(buf)
    end

    state
  catch
    :exit, _ -> state
  end

  @spec cancel_timer(EditorState.t()) :: EditorState.t()
  defp cancel_timer(%{space_leader_timer: nil} = state), do: state

  defp cancel_timer(%{space_leader_timer: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    # Flush any already-delivered message
    receive do
      {:space_leader_timeout, ^ref} -> :ok
    after
      0 -> :ok
    end

    %{state | space_leader_timer: nil}
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

  @spec execute_leader_command(EditorState.t(), atom() | tuple()) :: EditorState.t()
  defp execute_leader_command(state, cmd) do
    case Commands.execute(state, cmd) do
      {s, {:whichkey_update, wk}} -> %{s | whichkey: wk}
      s when is_map(s) -> s
      {s, _action} -> s
    end
  end
end
