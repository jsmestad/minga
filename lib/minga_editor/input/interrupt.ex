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
  - Picker → closed
  - Which-key popup → dismissed
  - Conflict prompt → dismissed
  - Completion menu → closed
  - Status message → cleared
  - Agent pending prefix → cleared

  A `*Messages*` log entry records what was reset for debuggability.
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

  alias MingaEditor.Agent.UIState
  alias Minga.Editing.Completion
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Picker
  alias MingaEditor.State.WhichKey
  alias MingaEditor.VimState
  alias Minga.Mode
  alias MingaEditor.Workspace.State, as: WorkspaceState

  # Ctrl-G sends codepoint 7 (BEL / ASCII control code for ^G).
  @ctrl_g 7

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
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
    state = EditorState.clear_status(state)

    {state, resets}
  end

  @spec maybe_reset_scope(EditorState.t(), [String.t()]) :: {EditorState.t(), [String.t()]}
  defp maybe_reset_scope(%{workspace: %{keymap_scope: :editor}} = state, resets),
    do: {state, resets}

  defp maybe_reset_scope(%{workspace: %{keymap_scope: scope}} = state, resets) do
    {EditorState.update_workspace(state, &WorkspaceState.set_keymap_scope(&1, :editor)),
     ["scope #{scope} → :editor" | resets]}
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

      {EditorState.update_workspace(state, &WorkspaceState.set_editing(&1, new_vim)),
       ["mode state reset (pending sequence cleared)" | resets]}
    else
      {state, resets}
    end
  end

  # Checks if mode_state has any pending state that should be cleared.
  @spec mode_state_dirty?(Mode.state(), Mode.state()) :: boolean()
  defp mode_state_dirty?(current, fresh) do
    current.leader_node != fresh.leader_node or
      current.prefix_node != fresh.prefix_node or
      current.pending != fresh.pending or
      current.describe_key != fresh.describe_key or
      current.count != fresh.count
  end

  @spec maybe_close_picker(EditorState.t(), [String.t()]) :: {EditorState.t(), [String.t()]}
  defp maybe_close_picker(%{shell_state: %{picker_ui: %Picker{picker: nil}}} = state, resets),
    do: {state, resets}

  defp maybe_close_picker(state, resets) do
    {EditorState.set_picker_ui(state, %Picker{}), ["picker closed" | resets]}
  end

  @spec maybe_close_whichkey(EditorState.t(), [String.t()]) :: {EditorState.t(), [String.t()]}
  defp maybe_close_whichkey(
         %{shell_state: %{whichkey: %WhichKey{node: nil, show: false}}} = state,
         resets
       ),
       do: {state, resets}

  defp maybe_close_whichkey(state, resets) do
    wk = EditorState.whichkey(state)
    {EditorState.set_whichkey(state, WhichKey.clear(wk)), ["which-key dismissed" | resets]}
  end

  @spec maybe_close_conflict(EditorState.t(), [String.t()]) :: {EditorState.t(), [String.t()]}
  defp maybe_close_conflict(%{workspace: %{pending_conflict: nil}} = state, resets),
    do: {state, resets}

  defp maybe_close_conflict(state, resets) do
    {EditorState.update_workspace(state, &WorkspaceState.set_pending_conflict(&1, nil)),
     ["conflict prompt dismissed" | resets]}
  end

  @spec maybe_close_completion(EditorState.t(), [String.t()]) :: {EditorState.t(), [String.t()]}
  defp maybe_close_completion(%{workspace: %{completion: nil}} = state, resets),
    do: {state, resets}

  defp maybe_close_completion(%{workspace: %{completion: %Completion{}}} = state, resets) do
    {EditorState.update_workspace(state, &WorkspaceState.set_completion(&1, nil)),
     ["completion closed" | resets]}
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
