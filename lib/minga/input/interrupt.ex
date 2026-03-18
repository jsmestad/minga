defmodule Minga.Input.Interrupt do
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
  - Picker → closed
  - Which-key popup → dismissed
  - Conflict prompt → dismissed
  - Completion menu → closed
  - Status message → cleared
  - Agent pending prefix → cleared

  A `*Messages*` log entry records what was reset for debuggability.
  """

  @behaviour Minga.Input.Handler

  alias Minga.Agent.UIState
  alias Minga.Completion
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.State.Picker
  alias Minga.Editor.State.WhichKey
  alias Minga.Mode

  # Ctrl-G sends codepoint 7 (BEL / ASCII control code for ^G).
  @ctrl_g 7

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Input.Handler.result()
  def handle_key(state, @ctrl_g, 0) do
    {new_state, resets} = reset_to_known_good(state)
    new_state = log_resets(new_state, resets)
    {:handled, new_state}
  end

  def handle_key(state, _codepoint, _modifiers), do: {:passthrough, state}

  # ── Reset logic ──────────────────────────────────────────────────────────

  @spec reset_to_known_good(EditorState.t()) :: {EditorState.t(), [String.t()]}
  defp reset_to_known_good(state) do
    {state, resets} = {state, []}

    {state, resets} = maybe_reset_scope(state, resets)
    {state, resets} = maybe_reset_mode(state, resets)
    {state, resets} = maybe_close_picker(state, resets)
    {state, resets} = maybe_close_whichkey(state, resets)
    {state, resets} = maybe_close_conflict(state, resets)
    {state, resets} = maybe_close_completion(state, resets)
    {state, resets} = maybe_clear_agent_prefix(state, resets)
    state = %{state | status_msg: nil}

    {state, resets}
  end

  @spec maybe_reset_scope(EditorState.t(), [String.t()]) :: {EditorState.t(), [String.t()]}
  defp maybe_reset_scope(%{keymap_scope: :editor} = state, resets), do: {state, resets}

  defp maybe_reset_scope(%{keymap_scope: scope} = state, resets) do
    {%{state | keymap_scope: :editor}, ["scope #{scope} → :editor" | resets]}
  end

  @spec maybe_reset_mode(EditorState.t(), [String.t()]) :: {EditorState.t(), [String.t()]}
  defp maybe_reset_mode(%{vim: %{mode: mode} = vim} = state, resets) when mode != :normal do
    new_vim = %{vim | mode: :normal, mode_state: Mode.initial_state()}
    {%{state | vim: new_vim}, ["mode #{mode} → :normal" | resets]}
  end

  defp maybe_reset_mode(%{vim: vim} = state, resets) do
    fresh_state = Mode.initial_state()

    if mode_state_dirty?(vim.mode_state, fresh_state) do
      new_vim = %{vim | mode_state: fresh_state}
      {%{state | vim: new_vim}, ["mode state reset (pending sequence cleared)" | resets]}
    else
      {state, resets}
    end
  end

  # Checks if mode_state has any pending state that should be cleared.
  @spec mode_state_dirty?(Mode.state(), Mode.state()) :: boolean()
  defp mode_state_dirty?(current, fresh) do
    current.leader_node != fresh.leader_node or
      current.prefix_node != fresh.prefix_node or
      current.pending_find != fresh.pending_find or
      current.pending_replace != fresh.pending_replace or
      current.pending_mark != fresh.pending_mark or
      current.pending_register != fresh.pending_register or
      current.count != fresh.count
  end

  @spec maybe_close_picker(EditorState.t(), [String.t()]) :: {EditorState.t(), [String.t()]}
  defp maybe_close_picker(%{picker_ui: %Picker{picker: nil}} = state, resets),
    do: {state, resets}

  defp maybe_close_picker(state, resets) do
    {%{state | picker_ui: %Picker{}}, ["picker closed" | resets]}
  end

  @spec maybe_close_whichkey(EditorState.t(), [String.t()]) :: {EditorState.t(), [String.t()]}
  defp maybe_close_whichkey(%{whichkey: %WhichKey{node: nil, show: false}} = state, resets),
    do: {state, resets}

  defp maybe_close_whichkey(%{whichkey: wk} = state, resets) do
    {%{state | whichkey: WhichKey.clear(wk)}, ["which-key dismissed" | resets]}
  end

  @spec maybe_close_conflict(EditorState.t(), [String.t()]) :: {EditorState.t(), [String.t()]}
  defp maybe_close_conflict(%{pending_conflict: nil} = state, resets), do: {state, resets}

  defp maybe_close_conflict(state, resets) do
    {%{state | pending_conflict: nil}, ["conflict prompt dismissed" | resets]}
  end

  @spec maybe_close_completion(EditorState.t(), [String.t()]) :: {EditorState.t(), [String.t()]}
  defp maybe_close_completion(%{completion: nil} = state, resets), do: {state, resets}

  defp maybe_close_completion(%{completion: %Completion{}} = state, resets) do
    {%{state | completion: nil}, ["completion closed" | resets]}
  end

  @spec maybe_clear_agent_prefix(EditorState.t(), [String.t()]) :: {EditorState.t(), [String.t()]}
  defp maybe_clear_agent_prefix(state, resets) do
    case AgentAccess.agent_ui(state).pending_prefix do
      nil ->
        {state, resets}

      _prefix ->
        new_state = AgentAccess.update_agent_ui(state, &UIState.clear_prefix/1)
        {new_state, ["agent prefix cleared" | resets]}
    end
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
