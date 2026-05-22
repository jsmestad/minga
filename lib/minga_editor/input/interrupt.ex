defmodule MingaEditor.Input.Interrupt do
  @moduledoc """
  Ctrl-G interrupt handler. First handler in the input stack.

  Intercepts Ctrl-G (codepoint 7) and resets the editor to a known-good
  state. This is Minga's equivalent of Emacs's `C-g`: it cancels
  whatever is in progress and returns the user to normal mode in the
  editor scope.

  Sits before every other handler (including ConflictPrompt) so it
  works even when a modal overlay is swallowing all input. This is the
  last resort for focus confusion freezes where the editor is running
  but keys go to the wrong place.

  ## What gets reset

  - `keymap_scope` → `:editor`
  - Vim mode → `:normal` with fresh mode state
  - Modal overlay → dismissed
  - Which-key popup → dismissed
  - Agent pending prefix → cleared
  - Status message → cleared

  A `*Messages*` log entry records what was reset for debuggability.
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

  alias MingaEditor.Agent.UIState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.WhichKey
  alias MingaEditor.VimState
  alias Minga.Mode

  # Ctrl-G sends codepoint 7 (BEL / ASCII control code for ^G).
  @ctrl_g 7

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(state, @ctrl_g, 0) do
    {:handled, interrupt(state)}
  end

  def handle_key(state, _codepoint, _modifiers), do: {:passthrough, state}

  @doc "Resets transient editor state to a known-good baseline."
  @spec interrupt(EditorState.t()) :: EditorState.t()
  def interrupt(state) do
    {new_state, resets} = reset_to_known_good(state)
    log_resets(new_state, resets)
  end

  # ── Reset logic ──────────────────────────────────────────────────────────

  @spec reset_to_known_good(EditorState.t()) :: {EditorState.t(), [String.t()]}
  defp reset_to_known_good(state) do
    {state, resets} = {state, []}

    {state, resets} = maybe_reset_scope(state, resets)
    {state, resets} = maybe_reset_mode(state, resets)
    {state, resets} = maybe_dismiss_modal(state, resets)
    {state, resets} = maybe_clear_whichkey(state, resets)
    {state, resets} = maybe_clear_agent_prefix(state, resets)
    {state, resets} = maybe_clear_status(state, resets)

    {state, resets}
  end

  @spec maybe_reset_scope(EditorState.t(), [String.t()]) :: {EditorState.t(), [String.t()]}
  defp maybe_reset_scope(%{workspace: %{keymap_scope: :editor}} = state, resets),
    do: {state, resets}

  defp maybe_reset_scope(%{workspace: %{keymap_scope: scope}} = state, resets) do
    {EditorState.set_keymap_scope(state, :editor), ["scope #{scope} → :editor" | resets]}
  end

  @spec maybe_reset_mode(EditorState.t(), [String.t()]) :: {EditorState.t(), [String.t()]}
  defp maybe_reset_mode(%{workspace: %{editing: %{mode: mode}}} = state, resets)
       when mode != :normal do
    {EditorState.transition_mode(state, :normal), ["mode #{mode} → :normal" | resets]}
  end

  defp maybe_reset_mode(%{workspace: %{editing: vim}} = state, resets) do
    fresh_state = Mode.initial_state()

    if mode_state_dirty?(vim.mode_state, fresh_state) do
      new_vim = VimState.set_mode_state(vim, fresh_state)

      {EditorState.set_editing(state, new_vim),
       ["mode state reset (pending sequence cleared)" | resets]}
    else
      {state, resets}
    end
  end

  @spec mode_state_dirty?(term(), Minga.Mode.State.t()) :: boolean()
  defp mode_state_dirty?(%Minga.Mode.State{} = current, %Minga.Mode.State{} = fresh) do
    current.leader_node != fresh.leader_node or
      current.leader_keys != fresh.leader_keys or
      current.prefix_node != fresh.prefix_node or
      current.prefix_keys != fresh.prefix_keys or
      current.pending != fresh.pending or
      current.describe_key != fresh.describe_key or
      current.count != fresh.count or
      current.insert_changed != fresh.insert_changed
  end

  defp mode_state_dirty?(_current, _fresh), do: true

  @spec maybe_dismiss_modal(EditorState.t(), [String.t()]) :: {EditorState.t(), [String.t()]}
  defp maybe_dismiss_modal(state, resets) do
    if ModalOverlay.active?(EditorState.modal(state)) do
      {ModalOverlay.dismiss(state), ["modal dismissed" | resets]}
    else
      {state, resets}
    end
  end

  @spec maybe_clear_whichkey(EditorState.t(), [String.t()]) :: {EditorState.t(), [String.t()]}
  defp maybe_clear_whichkey(
         %{shell_state: %{whichkey: %WhichKey{node: nil, show: false}}} = state,
         resets
       ),
       do: {state, resets}

  defp maybe_clear_whichkey(state, resets) do
    wk = EditorState.whichkey(state)
    {EditorState.set_whichkey(state, WhichKey.clear(wk)), ["which-key dismissed" | resets]}
  end

  @spec maybe_clear_agent_prefix(EditorState.t(), [String.t()]) :: {EditorState.t(), [String.t()]}
  defp maybe_clear_agent_prefix(state, resets) do
    case AgentAccess.view(state).pending_prefix do
      nil ->
        {state, resets}

      _prefix ->
        new_state = AgentAccess.update_agent_ui(state, &UIState.clear_prefix/1)
        {new_state, ["agent prefix cleared" | resets]}
    end
  end

  @spec maybe_clear_status(EditorState.t(), [String.t()]) :: {EditorState.t(), [String.t()]}
  defp maybe_clear_status(%{shell_state: %{status_msg: nil}} = state, resets), do: {state, resets}

  defp maybe_clear_status(state, resets) do
    {EditorState.clear_status(state), ["status cleared" | resets]}
  end

  # ── Logging ──────────────────────────────────────────────────────────────

  @spec log_resets(EditorState.t(), [String.t()]) :: EditorState.t()
  defp log_resets(state, []) do
    Minga.Log.info(:editor, "C-g: already in clean state")
    state
  end

  defp log_resets(state, resets) do
    detail = resets |> Enum.reverse() |> Enum.join(", ")
    Minga.Log.info(:editor, "C-g: #{detail}")
    state
  end
end
