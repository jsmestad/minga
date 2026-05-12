defmodule MingaEditor.State.ModalOverlay do
  @moduledoc """
  Tagged-union representation of input-capturing modal overlays.

  Before this work, the picker, prompt, completion menu, conflict prompt,
  and dashboard each lived as an independent nullable field on shell
  state or workspace state. The type system permitted 32 combinations
  even though only six were meaningful, and `MingaEditor.Input.Interrupt`
  reset eight independent axes by hand. See `docs/UI-STATE-ANALYSIS.md`
  for the full analysis.

  This module replaces those fields with a single sum type:

      :none
      | {:picker, ModalOverlay.Picker.t()}
      | {:prompt, ModalOverlay.Prompt.t()}
      | {:completion, ModalOverlay.Completion.t()}
      | {:command_completion, ModalOverlay.CommandCompletion.t()}
      | {:conflict, ModalOverlay.Conflict.t()}
      | {:dashboard, ModalOverlay.Dashboard.t()}

  The modal field is the only storage location for these six variants. There is no dual-write migration path and no dev/test divergence assertion; future modal changes must go through this gate directly.

  **Do not mutate `:modal` directly**: always call this module's
  `open/3`, `transition/3`, `close/1`, `dismiss/1`, `update_completion/2`,
  or `put_completion_trigger/2`.

  ## Replacement policy

  `open/3` while a modal is already active replaces the previous one. There
  is no queue. The exception is `:conflict`: while a conflict prompt is
  active, other `open/3` calls are logged and return state unchanged. This
  matches the original behaviour where `ConflictPrompt` sat before every
  other handler in the input stack.

  `transition/3` performs the same replacement but without the sticky
  rule; it is intended for FSM-style steps where the caller has already
  decided that a transition must happen (e.g., picker → prompt).

  ## Per-tab semantics for completion

  Completion is logically per-tab — it tracks the cursor of the buffer
  that triggered it. The `Completion` payload carries an `owner` tab id;
  `dismiss_if_stale/1` runs from `EditorState.switch_tab/2` after the new
  context is restored, dismissing completion that no longer belongs to
  the active tab. Other variants live on shell state, which isn't
  snapshotted per tab, so they don't need this hook.
  """

  alias Minga.Editing.Completion
  alias MingaEditor.CompletionTrigger
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.ModalOverlay.CommandCompletion, as: CommandCompletionPayload
  alias MingaEditor.State.ModalOverlay.Completion, as: CompletionPayload
  alias MingaEditor.State.ModalOverlay.Conflict, as: ConflictPayload
  alias MingaEditor.State.ModalOverlay.Dashboard, as: DashboardPayload
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.ModalOverlay.Prompt, as: PromptPayload

  @type variant :: :picker | :prompt | :completion | :command_completion | :conflict | :dashboard

  @type payload ::
          PickerPayload.t()
          | PromptPayload.t()
          | CompletionPayload.t()
          | CommandCompletionPayload.t()
          | ConflictPayload.t()
          | DashboardPayload.t()

  @type t ::
          :none
          | {:picker, PickerPayload.t()}
          | {:prompt, PromptPayload.t()}
          | {:completion, CompletionPayload.t()}
          | {:command_completion, CommandCompletionPayload.t()}
          | {:conflict, ConflictPayload.t()}
          | {:dashboard, DashboardPayload.t()}

  # Single source of truth for the variant tag list. Adding a seventh modal
  # later means adding to this attribute plus the `t()` and `payload()`
  # types; the guards below stay correct automatically.
  @variants [:picker, :prompt, :completion, :command_completion, :conflict, :dashboard]

  # ── Pure queries on the modal value ────────────────────────────────────────

  @doc "Returns the closed modal (`:none`)."
  @spec none() :: t()
  def none, do: :none

  @doc """
  Returns the variant tag of `modal`, or `:none` when no modal is active.
  """
  @spec tag(t()) :: :none | variant()
  def tag(:none), do: :none
  def tag({tag, _payload}) when tag in @variants, do: tag

  @doc "Returns true when a modal is currently active (`modal != :none`)."
  @spec active?(t()) :: boolean()
  def active?(:none), do: false
  def active?({tag, _payload}) when tag in @variants, do: true

  @doc """
  Returns true when `modal` matches the given variant tag.

  `match(:none, :none)` is true; `match({:picker, _}, :picker)` is true.
  Any other combination is false.
  """
  @spec match(t(), :none | variant()) :: boolean()
  def match(:none, :none), do: true
  def match({tag, _payload}, tag) when tag in @variants, do: true
  def match(_modal, _tag), do: false

  # ── Mutating gate functions on EditorState ─────────────────────────────────

  @doc """
  Opens a modal overlay, replacing any active one.

  Conflict prompts are sticky: if the active modal is a conflict, calls
  to `open/3` for any other variant are logged and return state
  unchanged. To force a transition out of a conflict modal, call
  `close/1` or `dismiss/1` first, or use `transition/3`.
  """
  @spec open(EditorState.t(), variant(), payload()) :: EditorState.t()
  def open(%EditorState{} = state, variant, payload) do
    case state.shell_state.modal do
      {:conflict, _} when variant != :conflict ->
        Minga.Log.info(
          :editor,
          "ModalOverlay.open(#{inspect(variant)}) suppressed: conflict prompt is active"
        )

        state

      _ ->
        EditorState.set_modal(state, {variant, payload})
    end
  end

  @doc """
  Transitions the active modal to a new variant unconditionally.

  Equivalent to `open/3` except the conflict-sticky rule is bypassed.
  Use this when the caller has already decided the transition must
  happen (e.g., dismissing a picker into a prompt).
  """
  @spec transition(EditorState.t(), variant(), payload()) :: EditorState.t()
  def transition(%EditorState{} = state, variant, payload) do
    EditorState.set_modal(state, {variant, payload})
  end

  @doc """
  Closes the active modal cleanly.

  Used when the modal has completed its task (e.g., picker accepted,
  prompt submitted). No-op when no modal is active.
  """
  @spec close(EditorState.t()) :: EditorState.t()
  def close(%EditorState{} = state), do: do_close(state, :close)

  @doc """
  Dismisses the active modal as a cancellation.

  Used when the user backs out (Esc, Ctrl-G). Identical to `close/1` —
  the distinction exists so callers can express intent and future
  per-variant cleanup hooks can branch on it.
  """
  @spec dismiss(EditorState.t()) :: EditorState.t()
  def dismiss(%EditorState{} = state), do: do_close(state, :dismiss)

  @spec do_close(EditorState.t(), :close | :dismiss) :: EditorState.t()
  defp do_close(state, _kind) do
    case state.shell_state.modal do
      :none -> state
      _ -> EditorState.set_modal(state, :none)
    end
  end

  # ── Completion accessors and updaters ──────────────────────────────────────

  @doc """
  Returns the active `Completion.t()` when the modal is `{:completion, _}`,
  otherwise `nil`. Read site for chrome rendering, render-pipeline input
  build, and any code path that historically read `workspace.completion`.

  Accepts any struct or map that carries `shell_state.modal` so the
  RenderPipeline.Input flavour of state works the same as EditorState.
  """
  @spec completion(map()) :: Completion.t() | nil
  def completion(%{shell_state: %{modal: {:completion, %CompletionPayload{} = p}}}),
    do: p.completion

  def completion(_), do: nil

  @doc """
  Returns the active `CompletionTrigger.t()` from the completion payload,
  or a fresh trigger when no completion modal is active. Callers that just
  want to consult the trigger lifecycle (debounce, pending refs) without
  caring about completion state itself use this.
  """
  @spec completion_trigger(map()) :: CompletionTrigger.t()
  def completion_trigger(%{shell_state: %{modal: {:completion, %CompletionPayload{} = p}}}),
    do: p.trigger || CompletionTrigger.new()

  def completion_trigger(_), do: CompletionTrigger.new()

  @doc """
  Updates the inner `Completion.t()` of the active completion modal via
  `fun`. No-op when no completion modal is active. Use for menu-navigation
  events (move_up/move_down) that mutate `Completion` without changing
  the gate's variant.
  """
  @spec update_completion(EditorState.t(), (Completion.t() -> Completion.t())) :: EditorState.t()
  def update_completion(%EditorState{} = state, fun) when is_function(fun, 1) do
    case state.shell_state.modal do
      {:completion, %CompletionPayload{completion: comp} = payload} ->
        new_comp = fun.(comp)
        new_payload = CompletionPayload.put_completion(payload, new_comp)
        EditorState.set_modal(state, {:completion, new_payload})

      _ ->
        state
    end
  end

  @doc """
  Updates the completion trigger.

  Behaviour by current modal:
  - `:completion` — update the payload's trigger in place.
  - `:none` and trigger has pending activity (debounce timer or pending
    request) — open a new completion modal with `completion: nil` and the
    given trigger so the bridge state has somewhere to live until the LSP
    response arrives.
  - `:none` and trigger is empty — no-op.
  - any other variant — no-op (don't displace another modal for a backend
    bookkeeping update).
  """
  @spec put_completion_trigger(EditorState.t(), CompletionTrigger.t()) :: EditorState.t()
  def put_completion_trigger(%EditorState{} = state, trigger) do
    case state.shell_state.modal do
      {:completion, %CompletionPayload{} = payload} ->
        new_payload = CompletionPayload.put_trigger(payload, trigger)
        EditorState.set_modal(state, {:completion, new_payload})

      :none ->
        if trigger_active?(trigger) do
          payload = CompletionPayload.new(active_tab_id(state), trigger: trigger)
          EditorState.set_modal(state, {:completion, payload})
        else
          state
        end

      _ ->
        state
    end
  end

  @spec trigger_active?(CompletionTrigger.t()) :: boolean()
  defp trigger_active?(%{
         debounce_timer: timer,
         pending_ref: ref,
         pending_refs: refs
       }) do
    timer != nil or ref != nil or MapSet.size(refs) > 0
  end

  defp trigger_active?(_), do: false

  # ── Command completion accessors and updaters ──────────────────────────────

  @doc """
  Returns the active `CommandCompletionPayload.t()` when the modal is
  `{:command_completion, _}`, otherwise `nil`.
  """
  @spec command_completion(map()) :: CommandCompletionPayload.t() | nil
  def command_completion(%{
        shell_state: %{modal: {:command_completion, %CommandCompletionPayload{} = p}}
      }),
      do: p

  def command_completion(_), do: nil

  # ── Per-tab dismissal hook ─────────────────────────────────────────────────

  @doc """
  Dismisses the active completion modal when its `owner` no longer
  matches the now-active tab. Called from `EditorState.switch_tab/2` after
  the target tab's context is restored.

  Only completion has per-tab semantics; other modals live on shell state
  and don't snapshot per tab, so this is a no-op for them.
  """
  @spec dismiss_if_stale(EditorState.t()) :: EditorState.t()
  def dismiss_if_stale(%EditorState{} = state) do
    case state.shell_state.modal do
      {:completion, %CompletionPayload{owner: owner}} ->
        if active_tab_id(state) == owner do
          state
        else
          dismiss(state)
        end

      _ ->
        state
    end
  end

  @spec active_tab_id(EditorState.t()) :: term() | nil
  defp active_tab_id(%EditorState{shell_state: %{tab_bar: %{active_id: id}}}), do: id
  defp active_tab_id(%EditorState{}), do: nil
end
