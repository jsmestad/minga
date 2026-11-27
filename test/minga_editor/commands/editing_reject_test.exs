defmodule MingaEditor.Commands.EditingRejectTest do
  @moduledoc """
  `SPC a u` confirms the exact task, then either rejects all its changes or changes nothing.
  """

  use ExUnit.Case, async: true

  import MingaEditor.CommandStateHelpers

  alias Minga.Buffer.EditSource
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Commands.Editing
  alias MingaEditor.PromptUI
  alias MingaEditor.Shell.Traditional.NoticeWorkflow

  test "Cancel changes nothing and confirmation rejects only the named task" do
    buffer = start_buffer("a\nb\nc\n")
    replace(buffer, {0, 0}, 1, "first", EditSource.minga("older", "step-1"))
    replace(buffer, {1, 0}, 1, "second", EditSource.minga("current", "step-1"))
    replace(buffer, {2, 0}, 1, "third", EditSource.minga("current", "step-2"))
    replace(buffer, {2, 5}, 0, "!", EditSource.user())

    prompt = open_confirmation(command_state(buffer))
    assert label(prompt) =~ "Reject 2 changes from task current?"
    assert label(prompt) =~ "Your edits stay."

    {state, nil} = PromptUI.handle_key(prompt, ?n, 0)
    refute PromptUI.open?(state)
    assert BufferProcess.content(buffer) == "first\nsecond\nthird!\n"

    confirmed = state |> open_confirmation() |> confirm()
    refute PromptUI.open?(confirmed)
    assert BufferProcess.content(buffer) == "first\nb\nc!\n"
    assert NoticeWorkflow.message(confirmed) == "Rejected 2 changes"
  end

  test "a delayed Yes from an earlier prompt cannot activate its replacement" do
    buffer = start_buffer("before\n")
    replace(buffer, {0, 0}, 6, "after", EditSource.minga("t", "s1"))
    first = open_confirmation(command_state(buffer))
    old_generation = generation(first)
    {state, nil} = PromptUI.handle_key(first, 27, 0)
    second = open_confirmation(state)
    state = PromptUI.activate(second, old_generation, "Yes")

    assert PromptUI.open?(state)
    assert BufferProcess.content(buffer) == "after\n"
    state = PromptUI.activate(state, generation(second), "Yes")
    refute PromptUI.open?(state)
    assert BufferProcess.content(buffer) == "before\n"
  end

  test "a task edited after preview requires a new confirmation" do
    buffer = start_buffer("before\n")
    source = EditSource.minga("t", "s1")
    replace(buffer, {0, 0}, 6, "after", source)
    prompt = open_confirmation(command_state(buffer))
    replace(buffer, {0, 0}, 5, "different", source)

    state = confirm(prompt)
    assert BufferProcess.content(buffer) == "different\n"
    assert NoticeWorkflow.message(state) =~ "Open Reject all again"
  end

  test "a task your visible edit holds is refused without changing the buffer" do
    buffer = start_buffer("xay\n")
    replace(buffer, {0, 1}, 1, "bcd", EditSource.minga("t", "s1"))
    replace(buffer, {0, 2}, 1, "QR", EditSource.user())
    content = BufferProcess.content(buffer)

    state = buffer |> command_state() |> open_confirmation() |> confirm()

    assert BufferProcess.content(buffer) == content
    assert NoticeWorkflow.message(state) == "Nothing rejected. Your edit overlaps this task."
  end

  test "undo identifies the exact blocking step, and rejecting it makes your undo available" do
    buffer = blocked_buffer()
    state = Editing.execute(command_state(buffer), :undo)
    assert NoticeWorkflow.message(state) == "Undo blocked: Minga t/s1"
    assert BufferProcess.content(buffer) == "hello there"

    state = Editing.execute(state, :reject_blocking_change)
    assert NoticeWorkflow.message(state) == "Rejected the blocking Minga change"
    assert BufferProcess.content(buffer) == "hello world"
    Editing.execute(state, :undo)
    assert BufferProcess.content(buffer) == ""
  end

  test "the Keep key never decides a newer revision than the blocker it offered" do
    buffer = blocked_buffer()
    state = Editing.execute(command_state(buffer), :undo)
    replace(buffer, {0, 11}, 0, "!", EditSource.user())

    state = Editing.execute(state, :keep_blocking_change)
    assert NoticeWorkflow.message(state) =~ "Try undo again"
    assert BufferProcess.content(buffer) == "hello there!"
    assert {:ok, _target, {:minga, "t"}, 1} = Minga.Buffer.prepare_review(buffer, :latest)

    Editing.execute(state, :undo)
    assert BufferProcess.content(buffer) == "hello there"
    state = Editing.execute(command_state(buffer), :undo)
    assert NoticeWorkflow.message(state) == "Undo blocked: Minga t/s1"

    state = Editing.execute(state, :keep_blocking_change)
    assert NoticeWorkflow.message(state) == "Kept the blocking Minga change"
    assert BufferProcess.content(buffer) == "hello there"
    assert :empty = Minga.Buffer.prepare_review(buffer, :latest)
  end

  defp blocked_buffer do
    buffer = start_buffer("")
    :ok = BufferProcess.insert_text(buffer, "hello world")
    replace(buffer, {0, 6}, 5, "there", EditSource.minga("t", "s1"))
    buffer
  end

  defp open_confirmation(state), do: Editing.execute(state, :undo_agent_session)

  defp label(%{shell_runtime: %{state: %{modal: {:prompt, %{prompt_ui: %{label: label}}}}}}),
    do: label

  defp generation(%{
         shell_runtime: %{state: %{modal: {:prompt, %{prompt_ui: %{generation: generation}}}}}
       }),
       do: generation

  defp confirm(state) do
    {state, nil} = PromptUI.handle_key(state, ?y, 0)
    state
  end

  defp replace(buffer, position, length, text, source) do
    {:ok, _version} =
      BufferProcess.replace_byte_range_if_version(
        buffer,
        BufferProcess.version(buffer),
        position,
        length,
        text,
        source
      )
  end
end
