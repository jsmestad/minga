defmodule MingaEditor.State.ModalOverlay do
  @moduledoc """
  Pure tagged-union lifecycle owner for exclusive input-capturing modals.

  Conflict modals are sticky under `open/3`; `transition/3` is unconditional.
  Completion trigger bookkeeping and stale-tab dismissal receive the required
  active-tab context as values rather than reaching into Editor state.
  """

  alias Minga.Editing.Completion
  alias MingaEditor.CompletionTrigger
  alias MingaEditor.State.ModalOverlay.CommandCompletion, as: CommandCompletionPayload
  alias MingaEditor.State.ModalOverlay.Completion, as: CompletionPayload
  alias MingaEditor.State.ModalOverlay.Conflict, as: ConflictPayload
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.ModalOverlay.Prompt, as: PromptPayload

  @type variant :: :picker | :prompt | :completion | :command_completion | :conflict
  @type payload ::
          PickerPayload.t()
          | PromptPayload.t()
          | CompletionPayload.t()
          | CommandCompletionPayload.t()
          | ConflictPayload.t()
  @type t ::
          :none
          | {:picker, PickerPayload.t()}
          | {:prompt, PromptPayload.t()}
          | {:completion, CompletionPayload.t()}
          | {:command_completion, CommandCompletionPayload.t()}
          | {:conflict, ConflictPayload.t()}

  @variants [:picker, :prompt, :completion, :command_completion, :conflict]

  @doc "Returns the closed modal value."
  @spec none() :: t()
  def none, do: :none

  @doc "Returns the active tag, or `:none`."
  @spec tag(t()) :: :none | variant()
  def tag(:none), do: :none
  def tag({tag, _payload}) when tag in @variants, do: tag

  @doc "Returns whether a modal is active."
  @spec active?(t()) :: boolean()
  def active?(:none), do: false
  def active?({tag, _payload}) when tag in @variants, do: true

  @doc "Returns whether the modal has the expected tag."
  @spec match(t(), :none | variant()) :: boolean()
  def match(:none, :none), do: true
  def match({tag, _payload}, tag) when tag in @variants, do: true
  def match(_modal, _tag), do: false

  @doc "Opens a modal, preserving an active conflict against other variants."
  @spec open(t(), variant(), payload()) :: t()
  def open({:conflict, _payload} = modal, variant, _next) when variant != :conflict, do: modal
  def open(_modal, variant, payload) when variant in @variants, do: {variant, payload}

  @doc "Transitions to a modal unconditionally, bypassing conflict stickiness."
  @spec transition(t(), variant(), payload()) :: t()
  def transition(_modal, variant, payload) when variant in @variants, do: {variant, payload}

  @doc "Closes a completed modal."
  @spec close(t()) :: t()
  def close(:none), do: :none
  def close({_variant, _payload}), do: :none

  @doc "Dismisses a canceled modal."
  @spec dismiss(t()) :: t()
  def dismiss(modal), do: close(modal)

  @doc "Returns the inner completion value when completion is active."
  @spec completion(t()) :: Completion.t() | nil
  def completion({:completion, %CompletionPayload{completion: completion}}), do: completion
  def completion(_modal), do: nil

  @doc "Returns the active completion trigger or a fresh trigger."
  @spec completion_trigger(t()) :: CompletionTrigger.t()
  def completion_trigger({:completion, %CompletionPayload{trigger: trigger}}),
    do: trigger || CompletionTrigger.new()

  def completion_trigger(_modal), do: CompletionTrigger.new()

  @doc "Updates the active inner completion value."
  @spec update_completion(t(), (Completion.t() -> Completion.t())) :: t()
  def update_completion({:completion, %CompletionPayload{completion: completion} = payload}, fun)
      when is_function(fun, 1) do
    {:completion, CompletionPayload.put_completion(payload, fun.(completion))}
  end

  def update_completion(modal, _fun), do: modal

  @doc "Records completion-trigger lifecycle using explicit active-tab context."
  @spec put_completion_trigger(t(), CompletionTrigger.t(), term() | nil) :: t()
  def put_completion_trigger(
        {:completion, %CompletionPayload{} = payload},
        trigger,
        _active_tab_id
      ) do
    {:completion, CompletionPayload.put_trigger(payload, trigger)}
  end

  def put_completion_trigger(:none, trigger, active_tab_id) do
    if trigger_active?(trigger) do
      {:completion, CompletionPayload.new(active_tab_id, trigger: trigger)}
    else
      :none
    end
  end

  def put_completion_trigger(modal, _trigger, _active_tab_id), do: modal

  @doc "Returns the active command-completion payload."
  @spec command_completion(t()) :: CommandCompletionPayload.t() | nil
  def command_completion({:command_completion, %CommandCompletionPayload{} = payload}),
    do: payload

  def command_completion(_modal), do: nil

  @doc "Dismisses completion whose owner does not match the active tab id."
  @spec dismiss_if_stale(t(), term() | nil) :: t()
  def dismiss_if_stale({:completion, %CompletionPayload{owner: owner}} = modal, active_tab_id) do
    if owner == active_tab_id, do: modal, else: :none
  end

  def dismiss_if_stale(modal, _active_tab_id), do: modal

  @spec trigger_active?(CompletionTrigger.t()) :: boolean()
  defp trigger_active?(%{debounce_timer: timer, pending_ref: ref, pending_refs: refs}) do
    timer != nil or ref != nil or MapSet.size(refs) > 0
  end

  defp trigger_active?(_trigger), do: false
end
