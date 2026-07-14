defmodule MingaEditor.State.ModalOverlayTest do
  use ExUnit.Case, async: true

  alias Minga.Editing.Completion
  alias MingaEditor.CompletionTrigger
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.ModalOverlay.Completion, as: CompletionPayload
  alias MingaEditor.State.ModalOverlay.Conflict, as: ConflictPayload
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.ModalOverlay.Prompt, as: PromptPayload
  alias MingaEditor.State.Picker
  alias MingaEditor.State.Prompt
  alias MingaEditor.UI.Picker, as: UIPicker

  defp picker_payload(label \\ "test") do
    PickerPayload.new(%Picker{picker: UIPicker.new([], title: label), source: nil, restore: 7},
      opened_at: 1_000
    )
  end

  defp prompt_payload(text \\ "search") do
    PromptPayload.new(
      %Prompt{handler: SomeHandler, text: text, cursor: byte_size(text), label: ":"},
      opened_at: 1_001
    )
  end

  defp completion_payload(owner \\ 1) do
    CompletionPayload.new(owner, completion: Completion.new([], {0, 0}), opened_at: 1_003)
  end

  defp conflict_payload(buffer \\ self()) do
    ConflictPayload.new(buffer, "buffer changed on disk", opened_at: 1_004)
  end

  test "queries distinguish the exclusive tagged variants" do
    assert ModalOverlay.none() == :none
    assert ModalOverlay.tag(:none) == :none
    refute ModalOverlay.active?(:none)

    for {tag, payload} <- [
          picker: picker_payload(),
          prompt: prompt_payload(),
          completion: completion_payload(),
          conflict: conflict_payload()
        ] do
      modal = {tag, payload}
      assert ModalOverlay.tag(modal) == tag
      assert ModalOverlay.active?(modal)
      assert ModalOverlay.match(modal, tag)
      refute ModalOverlay.match(modal, :none)
    end
  end

  test "open replaces ordinary modals but preserves an active conflict" do
    picker = ModalOverlay.open(:none, {:picker, picker_payload()})
    prompt = prompt_payload("hello")
    assert ModalOverlay.open(picker, {:prompt, prompt}) == {:prompt, prompt}

    conflict = {:conflict, conflict_payload()}
    assert ModalOverlay.open(conflict, {:picker, picker_payload()}) == conflict

    next_conflict = conflict_payload(self())
    assert ModalOverlay.open(conflict, {:conflict, next_conflict}) == {:conflict, next_conflict}
  end

  test "modal transitions reject mismatched payload and legacy split arguments" do
    assert_raise FunctionClauseError, fn ->
      invoke(ModalOverlay, :open, [:none, {:picker, prompt_payload()}])
    end

    assert_raise FunctionClauseError, fn ->
      invoke(ModalOverlay, :open, [{:conflict, conflict_payload()}, {:picker, prompt_payload()}])
    end

    assert_raise FunctionClauseError, fn ->
      invoke(ModalOverlay, :transition, [:none, {:prompt, picker_payload()}])
    end

    assert_raise UndefinedFunctionError, fn ->
      invoke(ModalOverlay, :open, [:none, :picker, picker_payload()])
    end

    malformed = {:picker, prompt_payload()}

    for function <- [
          :tag,
          :active?,
          :close,
          :dismiss,
          :completion,
          :completion_trigger,
          :command_completion
        ] do
      assert_raise FunctionClauseError, fn -> invoke(ModalOverlay, function, [malformed]) end
    end

    assert_raise FunctionClauseError, fn -> invoke(ModalOverlay, :match, [malformed, :picker]) end

    assert_raise FunctionClauseError, fn ->
      invoke(CompletionPayload, :new, [:legacy_owner, []])
    end
  end

  test "transition bypasses conflict stickiness and close or dismiss returns none" do
    conflict = {:conflict, conflict_payload()}
    picker = picker_payload()
    assert ModalOverlay.transition(conflict, {:picker, picker}) == {:picker, picker}
    assert ModalOverlay.close({:picker, picker}) == :none
    assert ModalOverlay.dismiss(conflict) == :none
    assert ModalOverlay.close(:none) == :none
  end

  test "completion access and updates stay inside the modal value" do
    payload = completion_payload(7)
    modal = {:completion, payload}
    assert ModalOverlay.completion(modal) == payload.completion

    updated = ModalOverlay.update_completion(modal, &%{&1 | selected: 3})
    assert %Completion{selected: 3} = ModalOverlay.completion(updated)
    assert ModalOverlay.completion({:picker, picker_payload()}) == nil
  end

  test "completion trigger bookkeeping receives active-tab context explicitly" do
    trigger = %{CompletionTrigger.new() | pending_ref: make_ref()}
    modal = ModalOverlay.put_completion_trigger(:none, trigger, 42)
    assert {:completion, %CompletionPayload{owner: 42, trigger: ^trigger}} = modal

    replacement = %{trigger | pending_ref: nil, debounce_timer: make_ref()}
    updated = ModalOverlay.put_completion_trigger(modal, replacement, 99)
    assert ModalOverlay.completion_trigger(updated) == replacement

    assert ModalOverlay.put_completion_trigger({:picker, picker_payload()}, trigger, 42) ==
             {:picker, picker_payload()}
  end

  test "stale completion dismissal matches the explicit active tab identity" do
    modal = {:completion, completion_payload(7)}
    assert ModalOverlay.dismiss_if_stale(modal, 7) == modal
    assert ModalOverlay.dismiss_if_stale(modal, 8) == :none

    picker = {:picker, picker_payload()}
    assert ModalOverlay.dismiss_if_stale(picker, 8) == picker
  end

  # The indirection lets runtime boundary tests pass intentionally invalid typed values.
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp invoke(module, function, arguments), do: apply(module, function, arguments)
end
