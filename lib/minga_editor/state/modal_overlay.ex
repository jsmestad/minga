defmodule MingaEditor.State.ModalOverlay do
  @moduledoc """
  Pure tagged-union lifecycle owner for exclusive input-capturing modals.

  Conflict modals are sticky under `open/2`; `transition/2` is unconditional.
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
  alias MingaEditor.State.Tab

  @type variant :: :picker | :prompt | :completion | :command_completion | :conflict
  @type active ::
          {:picker, PickerPayload.t()}
          | {:prompt, PromptPayload.t()}
          | {:completion, CompletionPayload.t()}
          | {:command_completion, CommandCompletionPayload.t()}
          | {:conflict, ConflictPayload.t()}
  @type t :: :none | active()

  @variants [:picker, :prompt, :completion, :command_completion, :conflict]

  @doc "Returns the closed modal value."
  @spec none() :: t()
  def none, do: :none

  @doc "Returns the active tag, or `:none`."
  @spec tag(t()) :: :none | variant()
  def tag(:none), do: :none
  def tag({:picker, %PickerPayload{}}), do: :picker
  def tag({:prompt, %PromptPayload{}}), do: :prompt
  def tag({:completion, %CompletionPayload{}}), do: :completion
  def tag({:command_completion, %CommandCompletionPayload{}}), do: :command_completion
  def tag({:conflict, %ConflictPayload{}}), do: :conflict

  @doc "Returns whether a modal is active."
  @spec active?(t()) :: boolean()
  def active?(modal), do: tag(modal) != :none

  @doc "Returns whether the modal has the expected tag."
  @spec match(t(), :none | variant()) :: boolean()
  def match(modal, expected) when expected == :none or expected in @variants,
    do: tag(modal) == expected

  @doc "Opens an exact modal value, preserving an active conflict against other variants."
  @spec open(t(), active()) :: t()
  def open({:conflict, %ConflictPayload{}} = modal, {:picker, %PickerPayload{}}), do: modal
  def open({:conflict, %ConflictPayload{}} = modal, {:prompt, %PromptPayload{}}), do: modal

  def open({:conflict, %ConflictPayload{}} = modal, {:completion, %CompletionPayload{}}),
    do: modal

  def open(
        {:conflict, %ConflictPayload{}} = modal,
        {:command_completion, %CommandCompletionPayload{}}
      ),
      do: modal

  def open(_modal, {:picker, %PickerPayload{}} = next), do: next
  def open(_modal, {:prompt, %PromptPayload{}} = next), do: next
  def open(_modal, {:completion, %CompletionPayload{}} = next), do: next
  def open(_modal, {:command_completion, %CommandCompletionPayload{}} = next), do: next
  def open(_modal, {:conflict, %ConflictPayload{}} = next), do: next

  @doc "Transitions to an exact modal value unconditionally, bypassing conflict stickiness."
  @spec transition(t(), active()) :: active()
  def transition(_modal, {:picker, %PickerPayload{}} = next), do: next
  def transition(_modal, {:prompt, %PromptPayload{}} = next), do: next
  def transition(_modal, {:completion, %CompletionPayload{}} = next), do: next
  def transition(_modal, {:command_completion, %CommandCompletionPayload{}} = next), do: next
  def transition(_modal, {:conflict, %ConflictPayload{}} = next), do: next

  @doc "Closes a completed modal."
  @spec close(t()) :: :none
  def close(:none), do: :none
  def close({:picker, %PickerPayload{}}), do: :none
  def close({:prompt, %PromptPayload{}}), do: :none
  def close({:completion, %CompletionPayload{}}), do: :none
  def close({:command_completion, %CommandCompletionPayload{}}), do: :none
  def close({:conflict, %ConflictPayload{}}), do: :none

  @doc "Dismisses a canceled modal."
  @spec dismiss(t()) :: :none
  def dismiss(:none), do: :none
  def dismiss({:picker, %PickerPayload{}}), do: :none
  def dismiss({:prompt, %PromptPayload{}}), do: :none
  def dismiss({:completion, %CompletionPayload{}}), do: :none
  def dismiss({:command_completion, %CommandCompletionPayload{}}), do: :none
  def dismiss({:conflict, %ConflictPayload{}}), do: :none

  @doc "Returns the inner completion value when completion is active."
  @spec completion(t()) :: Completion.t() | nil
  def completion({:completion, %CompletionPayload{completion: completion}}), do: completion
  def completion(:none), do: nil
  def completion({:picker, %PickerPayload{}}), do: nil
  def completion({:prompt, %PromptPayload{}}), do: nil
  def completion({:command_completion, %CommandCompletionPayload{}}), do: nil
  def completion({:conflict, %ConflictPayload{}}), do: nil

  @doc "Returns the active completion trigger or a fresh trigger."
  @spec completion_trigger(t()) :: CompletionTrigger.t()
  def completion_trigger({:completion, %CompletionPayload{trigger: trigger}}),
    do: trigger || CompletionTrigger.new()

  def completion_trigger(:none), do: CompletionTrigger.new()
  def completion_trigger({:picker, %PickerPayload{}}), do: CompletionTrigger.new()
  def completion_trigger({:prompt, %PromptPayload{}}), do: CompletionTrigger.new()

  def completion_trigger({:command_completion, %CommandCompletionPayload{}}),
    do: CompletionTrigger.new()

  def completion_trigger({:conflict, %ConflictPayload{}}), do: CompletionTrigger.new()

  @doc "Updates the active inner completion value."
  @spec update_completion(t(), (Completion.t() -> Completion.t())) :: t()
  def update_completion({:completion, %CompletionPayload{completion: completion} = payload}, fun)
      when is_function(fun, 1) do
    {:completion, CompletionPayload.put_completion(payload, fun.(completion))}
  end

  def update_completion(:none, fun) when is_function(fun, 1), do: :none

  def update_completion({:picker, %PickerPayload{}} = modal, fun) when is_function(fun, 1),
    do: modal

  def update_completion({:prompt, %PromptPayload{}} = modal, fun) when is_function(fun, 1),
    do: modal

  def update_completion({:command_completion, %CommandCompletionPayload{}} = modal, fun)
      when is_function(fun, 1),
      do: modal

  def update_completion({:conflict, %ConflictPayload{}} = modal, fun) when is_function(fun, 1),
    do: modal

  @doc "Records completion-trigger lifecycle using explicit active-tab context."
  @spec put_completion_trigger(t(), CompletionTrigger.t(), Tab.id() | nil) :: t()
  def put_completion_trigger(
        modal,
        %{
          pending_ref: _pending_ref,
          pending_refs: %MapSet{},
          debounce_timer: _timer,
          trigger_position: _position,
          gen: _generation
        } = trigger,
        active_tab_id
      )
      when (is_integer(active_tab_id) and active_tab_id > 0) or is_nil(active_tab_id),
      do: do_put_completion_trigger(modal, trigger, active_tab_id)

  @spec do_put_completion_trigger(t(), CompletionTrigger.t(), Tab.id() | nil) :: t()
  defp do_put_completion_trigger(
         {:completion, %CompletionPayload{} = payload},
         trigger,
         _active_tab_id
       ),
       do: {:completion, CompletionPayload.put_trigger(payload, trigger)}

  defp do_put_completion_trigger(:none, trigger, active_tab_id) do
    if trigger_active?(trigger) do
      {:completion, CompletionPayload.new(active_tab_id, trigger: trigger)}
    else
      :none
    end
  end

  defp do_put_completion_trigger({:picker, %PickerPayload{}} = modal, _trigger, _active_tab_id),
    do: modal

  defp do_put_completion_trigger({:prompt, %PromptPayload{}} = modal, _trigger, _active_tab_id),
    do: modal

  defp do_put_completion_trigger(
         {:command_completion, %CommandCompletionPayload{}} = modal,
         _trigger,
         _active_tab_id
       ),
       do: modal

  defp do_put_completion_trigger(
         {:conflict, %ConflictPayload{}} = modal,
         _trigger,
         _active_tab_id
       ),
       do: modal

  @doc "Returns the active command-completion payload."
  @spec command_completion(t()) :: CommandCompletionPayload.t() | nil
  def command_completion({:command_completion, %CommandCompletionPayload{} = payload}),
    do: payload

  def command_completion(:none), do: nil
  def command_completion({:picker, %PickerPayload{}}), do: nil
  def command_completion({:prompt, %PromptPayload{}}), do: nil
  def command_completion({:completion, %CompletionPayload{}}), do: nil
  def command_completion({:conflict, %ConflictPayload{}}), do: nil

  @doc "Dismisses completion whose owner does not match the active tab id."
  @spec dismiss_if_stale(t(), Tab.id() | nil) :: t()
  def dismiss_if_stale({:completion, %CompletionPayload{owner: owner}} = modal, active_tab_id)
      when (is_integer(active_tab_id) and active_tab_id > 0) or is_nil(active_tab_id) do
    if owner == active_tab_id, do: modal, else: :none
  end

  def dismiss_if_stale(:none, active_tab_id)
      when (is_integer(active_tab_id) and active_tab_id > 0) or is_nil(active_tab_id),
      do: :none

  def dismiss_if_stale({:picker, %PickerPayload{}} = modal, active_tab_id)
      when (is_integer(active_tab_id) and active_tab_id > 0) or is_nil(active_tab_id),
      do: modal

  def dismiss_if_stale({:prompt, %PromptPayload{}} = modal, active_tab_id)
      when (is_integer(active_tab_id) and active_tab_id > 0) or is_nil(active_tab_id),
      do: modal

  def dismiss_if_stale({:command_completion, %CommandCompletionPayload{}} = modal, active_tab_id)
      when (is_integer(active_tab_id) and active_tab_id > 0) or is_nil(active_tab_id),
      do: modal

  def dismiss_if_stale({:conflict, %ConflictPayload{}} = modal, active_tab_id)
      when (is_integer(active_tab_id) and active_tab_id > 0) or is_nil(active_tab_id),
      do: modal

  @spec trigger_active?(CompletionTrigger.t()) :: boolean()
  defp trigger_active?(%{debounce_timer: timer, pending_ref: ref, pending_refs: refs}) do
    timer != nil or ref != nil or MapSet.size(refs) > 0
  end
end
