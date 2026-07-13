defmodule MingaEditor.Input.CUA.TUISpaceLeader do
  @moduledoc """
  BEAM-side SPC-as-leader for TUI frontends in CUA mode.

  Terminal emulators can't detect key-chord gestures (no keyUp events),
  so the GUI's Swift-side chord detection doesn't work. This handler
  uses a timer-based approach instead:

  1. SPC keyDown: insert space immediately, set pending, start timer.
  2. Next key while pending: check leader trie. If match, retract
     the space and enter leader/which-key mode. If no match, clear
     pending and let the key pass through normally.
  3. Timer fires: the space was real. Clear pending state.

  This adds ~200ms of "retract window" after each space, but no
  latency to the space itself (it appears instantly). The visual
  flash of the space being retracted is one frame at most.

  Only active when:
  - `editing_model: :cua`
  - `space_leader: :chord`
  - Backend is `:tui` (GUI uses `CUA.SpaceLeader` via gui_actions)

  In the handler stack, this sits above `Scoped` so it can intercept
  SPC before it reaches `CUA.Dispatch`.
  """

  @behaviour MingaEditor.Input.Handler

  alias Minga.Buffer
  alias MingaEditor.Commands
  alias MingaEditor.State, as: EditorState
  alias Minga.Keymap
  alias Minga.Keymap.Bindings

  @space 32
  @timeout_ms 200

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()

  # SPC with no modifiers: insert space and start pending timer
  def handle_key(state, @space, 0) do
    if active?(state) and not pending?(state) do
      buf = state.workspace.buffers.active

      if is_pid(buf) do
        try do
          Buffer.insert_char(buf, " ")
        catch
          :exit, _ -> :ok
        end
      end

      # Start the timeout timer
      timer = Process.send_after(self(), :space_leader_timeout, @timeout_ms)

      state =
        state
        |> put_space_leader_pending(true)
        |> put_space_leader_timer(timer)

      {:handled, state}
    else
      {:passthrough, state}
    end
  end

  # Any other key while SPC is pending checks the leader root. Once a prefix is active,
  # continue resolving keys inside the which-key node before normal CUA dispatch sees them.
  def handle_key(state, cp, mods) do
    handle_non_space_key(state, cp, mods, pending?(state), active_leader_node(state))
  end

  @spec handle_non_space_key(
          EditorState.t(),
          non_neg_integer(),
          non_neg_integer(),
          boolean(),
          Bindings.node_t() | nil
        ) ::
          MingaEditor.Input.Handler.result()
  defp handle_non_space_key(state, cp, mods, true, _node) do
    state = cancel_timer(state)
    state = put_space_leader_pending(state, false)

    trie = leader_trie(state)
    key = {cp, mods}

    case Map.get(trie.children, key) do
      nil ->
        {:passthrough, state}

      node ->
        state = retract_space(state)
        state = enter_leader(state, node)
        {:handled, state}
    end
  end

  defp handle_non_space_key(state, cp, mods, false, node) when is_map(node) do
    continue_leader(state, node, {cp, mods})
  end

  defp handle_non_space_key(state, _cp, _mods, false, _node) do
    {:passthrough, state}
  end

  @doc """
  Handles the timeout message. Called from Editor's handle_info.

  The space was real (no follow-up key within the timeout window).
  Clear the pending state.
  """
  @spec handle_timeout(EditorState.t()) :: EditorState.t()
  def handle_timeout(state) do
    state
    |> put_space_leader_pending(false)
    |> put_space_leader_timer(nil)
  end

  @doc """
  Returns true when TUI space leader should be active.

  Active when CUA mode, space_leader: :chord, and backend is :tui.
  GUI backends use the Swift-side chord detection instead.
  """
  @spec active?(map()) :: boolean()
  def active?(state) do
    Minga.Editing.active_model(state) == Minga.Editing.Model.CUA and
      Minga.Config.get(:space_leader) == :chord and
      state.backend == :tui
  catch
    :exit, _ -> false
  end

  # ── Private ──────────────────────────────────────────────────────────────

  @spec pending?(map()) :: boolean()
  defp pending?(%{shell_runtime: %{state: %{space_leader_pending: true}}}), do: true
  defp pending?(_state), do: false

  @spec active_leader_node(EditorState.t()) :: Bindings.node_t() | nil
  defp active_leader_node(state) do
    if active?(state), do: EditorState.whichkey(state).node, else: nil
  end

  @spec put_space_leader_pending(EditorState.t(), boolean()) :: EditorState.t()
  defp put_space_leader_pending(state, value) do
    EditorState.set_space_leader_pending(state, value)
  end

  @spec put_space_leader_timer(EditorState.t(), reference() | nil) :: EditorState.t()
  defp put_space_leader_timer(state, timer) do
    EditorState.set_space_leader_timer(state, timer)
  end

  @spec cancel_timer(EditorState.t()) :: EditorState.t()
  defp cancel_timer(%{shell_runtime: %{state: %{space_leader_timer: nil}}} = state), do: state

  defp cancel_timer(%{shell_runtime: %{state: %{space_leader_timer: timer}}} = state) do
    Process.cancel_timer(timer)
    put_space_leader_timer(state, nil)
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

  @spec enter_leader(EditorState.t(), Bindings.node_t()) :: EditorState.t()
  defp enter_leader(state, node) do
    if node.command != nil do
      execute_command(state, node.command)
    else
      {s, {:whichkey_update, wk}} = Commands.execute(state, {:leader_start, node})
      EditorState.set_whichkey(s, wk)
    end
  end

  @spec continue_leader(EditorState.t(), Bindings.node_t(), Bindings.key()) ::
          MingaEditor.Input.Handler.result()
  defp continue_leader(state, node, key) do
    case Bindings.lookup(node, key) do
      {:command, command} ->
        state = cancel_leader(state)
        {:handled, execute_command(state, command)}

      {:prefix, sub_node} ->
        {:handled, advance_leader(state, sub_node)}

      :not_found ->
        {:passthrough, cancel_leader(state)}
    end
  end

  @spec advance_leader(EditorState.t(), Bindings.node_t()) :: EditorState.t()
  defp advance_leader(state, node) do
    {s, {:whichkey_update, wk}} = Commands.execute(state, {:leader_progress, node})
    EditorState.set_whichkey(s, wk)
  end

  @spec cancel_leader(EditorState.t()) :: EditorState.t()
  defp cancel_leader(state) do
    {s, {:whichkey_update, wk}} = Commands.execute(state, :leader_cancel)
    EditorState.set_whichkey(s, wk)
  end

  @spec execute_command(EditorState.t(), atom() | tuple()) :: EditorState.t()
  defp execute_command(state, cmd) do
    case Commands.execute(state, cmd) do
      {s, {:whichkey_update, wk}} -> EditorState.set_whichkey(s, wk)
      s when is_map(s) -> s
      {s, _action} -> s
    end
  end

  @spec leader_trie(EditorState.t()) :: Bindings.node_t()
  defp leader_trie(state) do
    Keymap.leader_trie(EditorState.keymap_server(state))
  catch
    :exit, _ ->
      Minga.Log.warning(:config, "leader_trie unavailable; SPC bindings disabled this frame")
      Bindings.new()
  end
end
