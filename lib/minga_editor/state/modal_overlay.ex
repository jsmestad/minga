defmodule MingaEditor.State.ModalOverlay do
  @moduledoc """
  Tagged-union representation of input-capturing modal overlays.

  Today the picker, prompt, completion menu, conflict prompt, and
  dashboard live as independent nullable fields on shell state and
  workspace state. The type system permits 32 combinations even though
  only six are meaningful, and `MingaEditor.Input.Interrupt` resets eight
  independent axes by hand. See `docs/UI-STATE-ANALYSIS.md` for the full
  analysis.

  This module replaces those fields with a single sum type:

      :none
      | {:picker, ModalOverlay.Picker.t()}
      | {:prompt, ModalOverlay.Prompt.t()}
      | {:completion, ModalOverlay.Completion.t()}
      | {:conflict, ModalOverlay.Conflict.t()}
      | {:dashboard, ModalOverlay.Dashboard.t()}

  ## Migration phase: dual-write

  This is step 1 of 5 (Epic #1421). The new `:modal` field has been
  added to `Shell.Traditional.State` and `Shell.Board.State` but no
  callers read it yet. To keep the migration safe, every gate function
  here writes both:

  * `state.shell_state.modal` — the new sum-type field
  * The variant's legacy field — `picker_ui`, `prompt_ui`, `dashboard`,
    `workspace.completion`, or `workspace.pending_conflict`

  Variant-by-variant migrations (#1424-#1426) point reads at the new
  field one variant at a time. When all variants have migrated, #1427
  removes the dual-write and adds a Credo rule that forbids direct
  writes to the legacy fields.

  Until then, **do not mutate `:modal` directly**: always call this
  module's `open/3`, `transition/3`, `close/1`, or `dismiss/1`. Direct
  mutation of the legacy fields is still permitted (existing call
  sites have not been migrated), but a runtime assertion in `:dev` and
  `:test` builds crashes when the gate detects that its tracked variant
  has diverged from the legacy mirror. That surfaces stray writes in CI
  rather than letting them drift silently.

  ## Replacement policy

  `open/3` while a modal is already active replaces the previous one and
  clears its legacy slot. There is no queue. The exception is
  `:conflict`: while a conflict prompt is active, other `open/3` calls
  are logged and return state unchanged. This matches today's behavior
  where `ConflictPrompt` sits before every other handler in the input
  stack.

  `transition/3` performs the same replacement but without the sticky
  rule; it is intended for FSM-style steps where the caller has already
  decided that a transition must happen (e.g., picker → prompt).
  """

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.ModalOverlay.Completion, as: CompletionPayload
  alias MingaEditor.State.ModalOverlay.Conflict, as: ConflictPayload
  alias MingaEditor.State.ModalOverlay.Dashboard, as: DashboardPayload
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.ModalOverlay.Prompt, as: PromptPayload
  alias MingaEditor.State.Picker, as: PickerLegacy
  alias MingaEditor.State.Prompt, as: PromptLegacy
  alias MingaEditor.Workspace.State, as: WorkspaceState

  @type variant :: :picker | :prompt | :completion | :conflict | :dashboard

  @type payload ::
          PickerPayload.t()
          | PromptPayload.t()
          | CompletionPayload.t()
          | ConflictPayload.t()
          | DashboardPayload.t()

  @type t ::
          :none
          | {:picker, PickerPayload.t()}
          | {:prompt, PromptPayload.t()}
          | {:completion, CompletionPayload.t()}
          | {:conflict, ConflictPayload.t()}
          | {:dashboard, DashboardPayload.t()}

  @assert_consistency Mix.env() in [:dev, :test]

  # Single source of truth for the variant tag list. Adding a sixth modal
  # later means adding to this attribute plus the `t()` and `payload()`
  # types — the guards below stay correct automatically.
  @variants [:picker, :prompt, :completion, :conflict, :dashboard]

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

  Dual-write phase: in addition to setting `state.shell_state.modal`,
  this function mirrors the payload's underlying state into the variant's
  legacy field so existing readers continue to work.
  """
  @spec open(EditorState.t(), variant(), payload()) :: EditorState.t()
  def open(%EditorState{} = state, variant, payload) do
    state
    |> assert_consistency!()
    |> do_open(variant, payload)
    |> assert_consistency!()
  end

  @doc """
  Transitions the active modal to a new variant unconditionally.

  Equivalent to `open/3` except the conflict-sticky rule is bypassed.
  Use this when the caller has already decided the transition must
  happen (e.g., dismissing a picker into a prompt).
  """
  @spec transition(EditorState.t(), variant(), payload()) :: EditorState.t()
  def transition(%EditorState{} = state, variant, payload) do
    state
    |> assert_consistency!()
    |> do_set_modal(variant, payload)
    |> assert_consistency!()
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

  Used when the user backs out (Esc, Ctrl-G). Behavior is identical to
  `close/1` in the dual-write phase; the distinction exists so callers
  can express intent and so future per-variant cleanup hooks can branch
  on it.
  """
  @spec dismiss(EditorState.t()) :: EditorState.t()
  def dismiss(%EditorState{} = state), do: do_close(state, :dismiss)

  # ── Internals ──────────────────────────────────────────────────────────────

  @spec do_open(EditorState.t(), variant(), payload()) :: EditorState.t()
  defp do_open(state, variant, payload) do
    case state.shell_state.modal do
      {:conflict, _} when variant != :conflict ->
        Minga.Log.info(
          :editor,
          "ModalOverlay.open(#{inspect(variant)}) suppressed: conflict prompt is active"
        )

        # Sticky-conflict early return: state is unchanged, so the entry
        # assertion already proved consistency and there is nothing new to
        # check on the way out.
        state

      _ ->
        do_set_modal(state, variant, payload)
    end
  end

  @spec do_set_modal(EditorState.t(), variant(), payload()) :: EditorState.t()
  defp do_set_modal(state, variant, payload) do
    state
    |> clear_displaced_legacy()
    |> put_modal({variant, payload})
    |> mirror_to_legacy({variant, payload})
  end

  # `_kind` is intentionally unused in the dual-write phase. It is plumbed
  # through so future per-variant cleanup hooks (introduced once the legacy
  # mirror is removed in #1427) can branch on `:close` vs `:dismiss` without
  # changing the public API.
  @spec do_close(EditorState.t(), :close | :dismiss) :: EditorState.t()
  defp do_close(state, _kind) do
    state = assert_consistency!(state)

    case state.shell_state.modal do
      :none ->
        state

      _ ->
        state
        |> clear_displaced_legacy()
        |> put_modal(:none)
        |> assert_consistency!()
    end
  end

  # Clears the legacy slot of whichever variant is currently tracked in
  # `state.shell_state.modal`. No-op when the modal is `:none`.
  @spec clear_displaced_legacy(EditorState.t()) :: EditorState.t()
  defp clear_displaced_legacy(state) do
    case state.shell_state.modal do
      :none ->
        state

      {:picker, _} ->
        EditorState.set_picker_ui(state, %PickerLegacy{})

      {:prompt, _} ->
        EditorState.set_prompt_ui(state, %PromptLegacy{})

      {:dashboard, _} ->
        EditorState.close_dashboard(state)

      {:completion, _} ->
        EditorState.update_workspace(state, &WorkspaceState.set_completion(&1, nil))

      {:conflict, _} ->
        EditorState.update_workspace(state, &WorkspaceState.set_pending_conflict(&1, nil))
    end
  end

  # Writes the payload's underlying state to the variant's legacy slot.
  @spec mirror_to_legacy(EditorState.t(), {variant(), payload()}) :: EditorState.t()
  defp mirror_to_legacy(state, {:picker, %PickerPayload{picker_ui: pui}}) do
    EditorState.set_picker_ui(state, pui)
  end

  defp mirror_to_legacy(state, {:prompt, %PromptPayload{prompt_ui: pui}}) do
    EditorState.set_prompt_ui(state, pui)
  end

  defp mirror_to_legacy(state, {:dashboard, %DashboardPayload{state: dash}}) do
    EditorState.set_dashboard(state, dash)
  end

  defp mirror_to_legacy(state, {:completion, %CompletionPayload{completion: comp}}) do
    EditorState.update_workspace(state, &WorkspaceState.set_completion(&1, comp))
  end

  defp mirror_to_legacy(state, {:conflict, %ConflictPayload{} = conflict}) do
    legacy = ConflictPayload.to_legacy(conflict)
    EditorState.update_workspace(state, &WorkspaceState.set_pending_conflict(&1, legacy))
  end

  @spec put_modal(EditorState.t(), t()) :: EditorState.t()
  defp put_modal(state, modal) do
    EditorState.set_modal(state, modal)
  end

  # ── Divergence assertion ───────────────────────────────────────────────────
  #
  # The assertion runs before and after every gate function in `:dev` and
  # `:test`. When the gate is tracking a variant, the legacy slot for that
  # variant must equal the payload's underlying state. Any mismatch means
  # legacy state was mutated outside this gate; we crash so the offending
  # caller surfaces in CI.
  #
  # When `:modal` is `:none`, the gate makes no claims about legacy slots —
  # they remain managed by their pre-migration callers.

  if @assert_consistency do
    @spec assert_consistency!(EditorState.t()) :: EditorState.t()
    defp assert_consistency!(%EditorState{} = state) do
      check_consistency!(state)
      state
    end

    @spec check_consistency!(EditorState.t()) :: :ok
    defp check_consistency!(%EditorState{} = state) do
      ss = state.shell_state
      ws = state.workspace

      case ss.modal do
        :none ->
          :ok

        {:picker, %PickerPayload{picker_ui: pui}} ->
          if ss.picker_ui != pui, do: raise_divergence!(:picker, pui, ss.picker_ui)
          :ok

        {:prompt, %PromptPayload{prompt_ui: pu}} ->
          if ss.prompt_ui != pu, do: raise_divergence!(:prompt, pu, ss.prompt_ui)
          :ok

        {:dashboard, %DashboardPayload{state: dash}} ->
          if ss.dashboard != dash, do: raise_divergence!(:dashboard, dash, ss.dashboard)
          :ok

        # NOTE for #1424+: the completion and conflict payloads live on
        # shell_state.modal, but their legacy mirrors live on `workspace`,
        # which is snapshotted per tab while shell_state is not. Once a
        # caller actually opens one of these variants, switching tabs will
        # swap workspace.completion / workspace.pending_conflict out from
        # under the gate and trip this assertion on the next call. Resolve
        # by either (a) clearing :modal on tab-switch via a hook, or
        # (b) moving these variants' authoritative state onto workspace.
        # This step intentionally does not pick — flagged in the next
        # ticket's developer notes.
        {:completion, %CompletionPayload{completion: comp}} ->
          if ws.completion != comp, do: raise_divergence!(:completion, comp, ws.completion)
          :ok

        {:conflict, %ConflictPayload{} = conflict} ->
          expected = ConflictPayload.to_legacy(conflict)

          if ws.pending_conflict != expected,
            do: raise_divergence!(:conflict, expected, ws.pending_conflict)

          :ok
      end
    end

    @spec raise_divergence!(variant(), term(), term()) :: no_return()
    defp raise_divergence!(variant, expected, found) do
      raise """
      MingaEditor.State.ModalOverlay divergence: tracked variant #{inspect(variant)} \
      diverges from its legacy mirror. The gate expected the legacy slot to equal \
      the payload's underlying state, but found a different value. This means the \
      legacy field was mutated without going through ModalOverlay.

        expected: #{inspect(expected, pretty: true, limit: :infinity)}
        found:    #{inspect(found, pretty: true, limit: :infinity)}
      """
    end
  else
    @spec assert_consistency!(EditorState.t()) :: EditorState.t()
    defp assert_consistency!(state), do: state
  end
end
