defmodule MingaEditor.Input.CUA.TUISpaceLeader do
  @moduledoc """
  BEAM-side SPC-as-leader for TUI frontends in CUA mode.

  Terminal emulators can't detect key-chord gestures (no keyUp events),
  so the GUI's Swift-side chord detection doesn't work. This handler
  uses a timer-based approach instead:

  1. SPC keyDown: type the space into the focused file buffer immediately,
     set pending, start timer.
  2. Next key while pending: check leader trie. If match, retract
     the space and enter leader/which-key mode. If no match, clear
     pending and let the key pass through normally.
  3. Timer fires: the space was real. Clear pending state.

  This adds ~200ms of "retract window" after each space, but no
  latency to the space itself (it appears instantly). The visual
  flash of the space being retracted is one frame at most.

  The focused surface decides where the space goes. A focused file window takes it as described above. A focused Agent composer owns its text in a lower handler, so SPC passes through as a plain space. Agent chat navigation and a focused bottom panel take no text, so the window opens without a space and the file buffer behind them never changes: a leader key still starts the leader there, and any other key drops the space. The window records the buffer that took the space, so a retraction deletes it from that buffer and nowhere else.

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
  alias MingaEditor.Input.CUA.SpaceTarget
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias Minga.Keymap
  alias Minga.Keymap.Bindings

  @space 32
  @timeout_ms 200

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()

  # SPC with no modifiers: the focused surface decides what the space is.
  def handle_key(state, @space, 0) do
    if active?(state) and not pending?(state) do
      handle_space(state, SpaceTarget.resolve(state))
    else
      {:passthrough, state}
    end
  end

  # Any other key while SPC is pending checks the leader root. Once a prefix is active,
  # continue resolving keys inside the which-key node before normal CUA dispatch sees them.
  def handle_key(state, cp, mods) do
    handle_non_space_key(state, cp, mods, pending?(state), active_leader_node(state))
  end

  # A focused composer or overlay owns its text in another handler; SPC is a plain
  # space there. Otherwise type the space into the focused file buffer, if any,
  # and open the retract window.
  @spec handle_space(EditorState.t(), SpaceTarget.t()) :: MingaEditor.Input.Handler.result()
  defp handle_space(state, {:composer, _prompt}), do: {:passthrough, state}
  defp handle_space(state, :overlay), do: {:passthrough, state}

  defp handle_space(state, target) do
    {generation, state} = begin_window(state, type_space(target))
    timer = Process.send_after(self(), {:space_leader_timeout, generation}, @timeout_ms)
    {:handled, install_timer(state, generation, timer)}
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
    space_buffer = space_buffer(state)
    state = cancel(state)

    trie = leader_trie(state)
    key = {cp, mods}

    case Map.get(trie.children, key) do
      nil ->
        {:passthrough, state}

      node ->
        retract_space(space_buffer)
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

  @doc "Expires a matching timeout generation and ignores stale deliveries."
  @spec handle_timeout(EditorState.t(), non_neg_integer()) :: EditorState.t()
  def handle_timeout(%EditorState{} = state, generation) do
    case Runtime.state(state.shell_runtime) do
      %TraditionalState{} = shell_state ->
        {_result, shell_state} = TraditionalState.expire_space_leader(shell_state, generation)
        install_shell_state(state, shell_state)

      _extension_state ->
        state
    end
  end

  @doc "Cancels and resets the current timeout window."
  @spec cancel(EditorState.t()) :: EditorState.t()
  def cancel(%EditorState{} = state) do
    case Runtime.state(state.shell_runtime) do
      %TraditionalState{} = shell_state ->
        cancel_timer(TraditionalState.space_leader_timer(shell_state))
        install_shell_state(state, TraditionalState.reset_space_leader(shell_state))

      _extension_state ->
        state
    end
  end

  @doc """
  Returns true when TUI space leader should be active.

  Active when CUA mode, space_leader: :chord, and backend is :tui.
  GUI backends use the Swift-side chord detection instead.
  """
  @spec active?(map()) :: boolean()
  def active?(state) do
    match?(%TraditionalState{}, Runtime.state(state.shell_runtime)) and
      Minga.Editing.active_model(state) == Minga.Editing.Model.CUA and
      Minga.Config.get(:space_leader) == :chord and
      state.frontend.backend == :tui
  catch
    :exit, _ -> false
  end

  # ── Private ──────────────────────────────────────────────────────────────

  @spec pending?(map()) :: boolean()
  defp pending?(%{shell_runtime: %{state: %TraditionalState{} = shell_state}}),
    do: TraditionalState.space_leader_pending?(shell_state)

  defp pending?(_state), do: false

  @spec space_buffer(EditorState.t()) :: pid() | nil
  defp space_buffer(%{shell_runtime: %{state: %TraditionalState{} = shell_state}}),
    do: TraditionalState.space_leader_buffer(shell_state)

  defp space_buffer(_state), do: nil

  @spec type_space({:buffer, pid()} | :no_text) :: pid() | nil
  defp type_space(:no_text), do: nil

  defp type_space({:buffer, buf}) do
    Buffer.insert_char(buf, " ")
    buf
  catch
    :exit, _ -> nil
  end

  @spec active_leader_node(EditorState.t()) :: Bindings.node_t() | nil
  defp active_leader_node(state) do
    if active?(state), do: state.shell_runtime.state.whichkey.node, else: nil
  end

  @spec begin_window(EditorState.t(), pid() | nil) :: {non_neg_integer(), EditorState.t()}
  defp begin_window(%EditorState{} = state, space_buffer) do
    %TraditionalState{} = shell_state = Runtime.state(state.shell_runtime)
    {generation, shell_state} = TraditionalState.begin_space_leader(shell_state, space_buffer)
    {generation, install_shell_state(state, shell_state)}
  end

  @spec install_timer(EditorState.t(), non_neg_integer(), reference()) :: EditorState.t()
  defp install_timer(%EditorState{} = state, generation, timer) do
    %TraditionalState{} = shell_state = Runtime.state(state.shell_runtime)

    install_shell_state(
      state,
      TraditionalState.install_space_leader_timer(shell_state, generation, timer)
    )
  end

  @spec install_shell_state(EditorState.t(), TraditionalState.t()) :: EditorState.t()
  defp install_shell_state(%EditorState{} = state, %TraditionalState{} = shell_state) do
    %{
      state
      | shell_runtime:
          MingaEditor.Shell.Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }
  end

  @spec cancel_timer(reference() | nil) :: :ok
  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) when is_reference(timer) do
    Process.cancel_timer(timer)
    :ok
  end

  @spec retract_space(pid() | nil) :: :ok
  defp retract_space(nil), do: :ok

  defp retract_space(buf) do
    Buffer.break_undo_coalescing(buf)
    Buffer.delete_before(buf)
    Buffer.break_undo_coalescing(buf)
    :ok
  catch
    :exit, _ -> :ok
  end

  @spec enter_leader(EditorState.t(), Bindings.node_t()) :: EditorState.t()
  defp enter_leader(state, node) do
    if node.command != nil do
      execute_command(state, node.command)
    else
      Commands.execute(state, {:leader_start, node})
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
    Commands.execute(state, {:leader_progress, node})
  end

  @spec cancel_leader(EditorState.t()) :: EditorState.t()
  defp cancel_leader(state) do
    Commands.execute(state, :leader_cancel)
  end

  @spec execute_command(EditorState.t(), atom() | tuple()) :: EditorState.t()
  defp execute_command(state, cmd) do
    case Commands.execute(state, cmd) do
      s when is_map(s) -> s
      {s, _action} -> s
    end
  end

  @spec leader_trie(EditorState.t()) :: Bindings.node_t()
  defp leader_trie(state) do
    Keymap.leader_trie(state.interaction.keymap_server)
  catch
    :exit, _ ->
      Minga.Log.warning(:config, "leader_trie unavailable; SPC bindings disabled this frame")
      Bindings.new()
  end
end
