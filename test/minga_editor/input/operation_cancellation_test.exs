defmodule MingaEditor.Input.OperationCancellationTest do
  use ExUnit.Case, async: true

  alias Minga.Test.EffectProbe
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler
  alias MingaEditor.HoverPopup
  alias MingaEditor.HoverPopup.Builder, as: HoverBuilder
  alias MingaEditor.Input
  alias MingaEditor.Input.OperationCancellation
  alias MingaEditor.Input.Router
  alias MingaEditor.Input.WhichKey, as: WhichKeyInput
  alias MingaEditor.Shell.Traditional.HoverPopupWorkflow
  alias MingaEditor.Shell.Traditional.SignatureHelpWorkflow
  alias MingaEditor.Shell.Traditional.WhichKeyWorkflow
  alias MingaEditor.SignatureHelp
  alias MingaEditor.State.Feedback
  alias MingaEditor.State.OperationFeedback

  import MingaEditor.RenderPipeline.TestHelpers

  test "overlay stack documents completion, which-key, hover, signature, and operation precedence" do
    handlers = Input.overlay_handlers()

    indexes =
      Map.new(handlers, fn handler -> {handler, Enum.find_index(handlers, &(&1 == handler))} end)

    assert indexes[MingaEditor.Input.Completion] < indexes[MingaEditor.Input.WhichKey]
    assert indexes[MingaEditor.Input.WhichKey] < indexes[MingaEditor.Input.Hover]
    assert indexes[MingaEditor.Input.Hover] < indexes[MingaEditor.Input.SignatureHelp]

    assert indexes[MingaEditor.Input.SignatureHelp] <
             indexes[MingaEditor.Input.OperationCancellation]
  end

  test "which-key owns Escape while a prefix is active" do
    state = WhichKeyWorkflow.begin(base_state(), %{}, ["SPC"])

    assert {:handled, dismissed} = WhichKeyInput.handle_key(state, 27, 0)
    assert dismissed.shell_runtime.state.whichkey.node == nil
    assert dismissed.shell_runtime.state.whichkey.show == false
  end

  test "Editor reveal messages cannot reveal a replacement which-key generation" do
    first =
      base_state(rendering: :disabled)
      |> WhichKeyWorkflow.begin(%{?a => :first}, ["SPC"])

    first_generation = first.shell_runtime.state.whichkey.generation
    replacement = WhichKeyWorkflow.progress(first, %{?b => :second}, ["SPC", "b"])

    assert {:noreply, stale_delivery} =
             MingaEditor.handle_info({:whichkey_reveal, first_generation}, replacement)

    refute stale_delivery.shell_runtime.state.whichkey.show
    assert stale_delivery.shell_runtime.state.whichkey.prefix_keys == ["SPC", "b"]

    WhichKeyWorkflow.dismiss(stale_delivery)
  end

  test "higher interactive surfaces suppress lower content without replay" do
    signature_help =
      SignatureHelp.from_response(
        %{"signatures" => [%{"label" => "run(arg)", "parameters" => []}]},
        2,
        2
      )

    state = SignatureHelpWorkflow.show(base_state(), signature_help)
    focused_hover = "hover" |> HoverBuilder.new(2, 2) |> HoverPopup.focus()
    state = HoverPopupWorkflow.show(state, focused_hover)

    assert state.shell_runtime.state.signature_help == nil

    state = HoverPopupWorkflow.dismiss(state)
    assert state.shell_runtime.state.signature_help == nil

    state = HoverPopupWorkflow.show(state, HoverBuilder.new("hover", 2, 2))
    state = SignatureHelpWorkflow.show(state, signature_help)
    state = WhichKeyWorkflow.begin(state, %{?a => :action}, ["SPC"])

    assert state.shell_runtime.state.hover_popup == nil
    assert state.shell_runtime.state.signature_help == nil

    blocked =
      state
      |> HoverPopupWorkflow.show(HoverBuilder.new("blocked hover", 3, 3))
      |> SignatureHelpWorkflow.show(signature_help)

    assert blocked.shell_runtime.state.hover_popup == nil
    assert blocked.shell_runtime.state.signature_help == nil

    dismissed = WhichKeyWorkflow.dismiss(blocked)
    assert dismissed.shell_runtime.state.hover_popup == nil
    assert dismissed.shell_runtime.state.signature_help == nil
  end

  test "a missing scheduler reports and consumes the operation Escape" do
    state = base_state()

    {operation_feedback, _operation} =
      OperationFeedback.start(
        state.feedback.operation_feedback,
        :external_format,
        "buffer:missing-scheduler",
        "Formatting"
      )

    state = %{
      state
      | feedback: Feedback.accept_operation_feedback(state.feedback, operation_feedback)
    }

    assert {:handled, ^state} = OperationCancellation.handle_key(state, 27, 0)
  end

  test "focused hover receives Escape before the selected operation is canceled" do
    task_supervisor = start_supervised!(Task.Supervisor)

    scheduler =
      start_supervised!({EffectScheduler, task_supervisor: task_supervisor, observer: self()})

    assert :ok = EffectScheduler.attach(scheduler, self())

    state = base_state(rendering: :disabled, effect_scheduler: scheduler)

    {operation_feedback, operation} =
      OperationFeedback.start(
        state.feedback.operation_feedback,
        :external_format,
        "buffer:escape",
        "Formatting",
        cancelable?: true
      )

    state = %{
      state
      | feedback: Feedback.accept_operation_feedback(state.feedback, operation_feedback)
    }

    effect = %EffectProbe{
      test_pid: self(),
      label: :escape_cancel,
      payloads: [:escape_cancel],
      action: :wait
    }

    request = Request.new(effect, :escape_resource, Policy.fifo(0), operation.id)
    request_id = request.id
    assert {:ok, ^request_id, :running} = EffectScheduler.schedule(scheduler, request)
    assert_receive {:effect_started, :escape_cancel, _worker, [:escape_cancel]}

    popup = "hover" |> HoverBuilder.new(2, 2) |> HoverPopup.focus()
    state = HoverPopupWorkflow.show(state, popup)

    after_hover_escape = Router.dispatch(state, 27, 0)

    assert after_hover_escape.shell_runtime.state.hover_popup == nil
    assert %{running: 1} = EffectScheduler.stats(scheduler)
    refute_receive {:effect_result, ^scheduler, %Outcome{value: {:canceled, _reason}}}

    _after_operation_escape = Router.dispatch(after_hover_escape, 27, 0)

    assert_receive {:effect_result, ^scheduler, %Outcome{value: {:canceled, _reason}} = outcome}
    assert :ok = EffectScheduler.claim(scheduler, outcome)
    assert :ok = EffectScheduler.finalize(scheduler, outcome)
  end
end
