defmodule MingaEditor.UI.Picker.FetchEffectTest do
  @moduledoc "Focused execution and stale-application tests for async picker effects."

  use ExUnit.Case, async: true

  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.PickerUI
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.UI.Picker.Candidate
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.FetchEffect
  alias MingaEditor.UI.Picker.Item

  defmodule Source do
    @behaviour MingaEditor.UI.Picker.Source

    alias MingaEditor.UI.Picker.Item

    @impl true
    def title, do: "Effect source"

    @impl true
    def candidates(_context), do: []

    @impl true
    def async_fetch(%{picker_ui: %{context: %{test_pid: test_pid, action: action}}}) do
      send(test_pid, {:picker_source_called, action})
      perform(action)
    end

    @impl true
    def async?, do: true

    @impl true
    def on_select(_item, state), do: state

    @impl true
    def on_cancel(state), do: state

    defp perform(:success) do
      {:ok, [%Item{id: :one, label: "One"}], %{status: "loaded"}}
    end

    defp perform(:raise), do: raise("raised fetch")
    defp perform(:throw), do: throw(:thrown_fetch)
    defp perform(:exit), do: exit(:exited_fetch)
  end

  defmodule ReplacementSource do
    @behaviour MingaEditor.UI.Picker.Source

    @impl true
    def title, do: "Replacement source"

    @impl true
    def candidates(_context), do: []

    @impl true
    def async_fetch(context), do: Source.async_fetch(context)

    @impl true
    def async?, do: true

    @impl true
    def on_select(_item, state), do: state

    @impl true
    def on_cancel(state), do: state
  end

  test "request uses latest-wins policy, source resource, and contribution attribution" do
    context = context(:success)
    source = {:extension, :picker_extension}
    revision = make_ref()
    request = FetchEffect.request(Source, source, context, revision)

    assert request.resource == {:picker_fetch, Source}
    assert request.policy == Policy.latest_wins()
    assert request.source == source

    assert request.effect == %FetchEffect{
             source: Source,
             callback_source: source,
             context: context,
             revision: revision
           }
  end

  test "run fetches and normalizes candidates inside the effect worker" do
    effect = effect(:success)

    assert {:ok, {:ok, [item], [candidate], %{status: "loaded"}}} = FetchEffect.run(effect)
    assert item.label == "One"
    assert %Candidate{} = candidate
    assert_receive {:picker_source_called, :success}
  end

  test "run normalizes callback raise, throw, and exit failures" do
    assert {:error, {:picker_source_exception, "raised fetch"}} = FetchEffect.run(effect(:raise))
    assert {:error, {:picker_source_throw, :thrown_fetch}} = FetchEffect.run(effect(:throw))
    assert {:error, {:picker_source_exit, :exited_fetch}} = FetchEffect.run(effect(:exit))
  end

  test "source admission denial prevents the extension callback from running" do
    denied_source = {:extension, :missing_picker_extension}
    effect = %{effect(:success) | callback_source: denied_source}

    assert {:error, {:source_admission_denied, ^denied_source}} = FetchEffect.run(effect)
    refute_received {:picker_source_called, :success}
  end

  test "completed outcomes apply only to the live source and revision" do
    state = TestHelpers.base_state(rendering: :disabled)
    {state, revision} = PickerUI.open_loading(state, Source)
    request = FetchEffect.request(Source, nil, context(:success), revision)
    items = [%Item{id: :live, label: "Live"}]
    candidates = Candidate.from_items(items)
    outcome = Outcome.completed(request, {:ok, items, candidates, %{}})

    assert {applied, ^outcome} = FetchEffect.apply(state, outcome)
    {:picker, payload} = applied.shell_runtime.state.modal
    assert payload.picker_ui.load_status == :ready
    assert payload.picker_ui.picker.items == items

    stale_request = FetchEffect.request(Source, nil, context(:success), make_ref())
    stale_outcome = Outcome.completed(stale_request, {:ok, items, candidates, %{}})

    assert {^state, %Outcome{status: :stale, reason: :picker_closed_or_replaced}} =
             FetchEffect.apply(state, stale_outcome)
  end

  test "replacing source A with source B rejects a delayed A result" do
    state = TestHelpers.base_state(rendering: :disabled)
    {source_a_state, source_a_revision} = PickerUI.open_loading(state, Source)
    items = [%Item{id: :delayed_a, label: "Delayed A"}]

    source_a_outcome =
      Source
      |> FetchEffect.request(nil, context(:success), source_a_revision)
      |> Outcome.completed({:ok, items, Candidate.from_items(items), %{}})

    {source_b_state, _source_b_revision} =
      PickerUI.open_loading(source_a_state, ReplacementSource)

    assert {^source_b_state, %Outcome{status: :stale, reason: :picker_closed_or_replaced}} =
             FetchEffect.apply(source_b_state, source_a_outcome)

    {:picker, payload} = source_b_state.shell_runtime.state.modal
    assert payload.picker_ui.source == ReplacementSource
    refute Enum.any?(payload.picker_ui.picker.items, &(&1.label == "Delayed A"))
  end

  test "failed outcomes update a live picker while canceled outcomes do not" do
    state = TestHelpers.base_state(rendering: :disabled)
    {state, revision} = PickerUI.open_loading(state, Source)
    request = FetchEffect.request(Source, nil, context(:success), revision)

    failed = Outcome.failed(request, {:picker_source_throw, :bad})
    assert {failed_state, ^failed} = FetchEffect.apply(state, failed)
    {:picker, failed_payload} = failed_state.shell_runtime.state.modal
    assert failed_payload.picker_ui.load_status == {:error, "Source failed: :bad"}

    canceled = Outcome.canceled(request, :source_canceled)
    assert {^state, ^canceled} = FetchEffect.apply(state, canceled)
  end

  test "an old scheduler generation cannot apply into replacement Editor state" do
    old_scheduler = spawn(fn -> receive do: (:stop -> :ok) end)
    current_scheduler = spawn(fn -> receive do: (:stop -> :ok) end)
    state = %{TestHelpers.base_state(rendering: :disabled) | effect_scheduler: current_scheduler}
    {state, revision} = PickerUI.open_loading(state, Source)
    request = FetchEffect.request(Source, nil, context(:success), revision)
    items = [%Item{id: :old, label: "Old generation"}]
    outcome = Outcome.completed(request, {:ok, items, Candidate.from_items(items), %{}})

    assert {:noreply, ^state} =
             MingaEditor.handle_info({:effect_result, old_scheduler, outcome}, state)

    send(old_scheduler, :stop)
    send(current_scheduler, :stop)
  end

  test "closing the picker makes an already-completed outcome stale" do
    state = TestHelpers.base_state(rendering: :disabled)
    {state, revision} = PickerUI.open_loading(state, Source)
    request = FetchEffect.request(Source, nil, context(:success), revision)
    items = [%Item{id: :late, label: "Late"}]
    outcome = Outcome.completed(request, {:ok, items, Candidate.from_items(items), %{}})
    closed = PickerUI.close(state)

    assert {^closed, %Outcome{status: :stale}} = FetchEffect.apply(closed, outcome)
  end

  defp context(action) do
    TestHelpers.base_state(rendering: :disabled)
    |> Context.from_editor_state(%{test_pid: self(), action: action})
  end

  defp effect(action) do
    %FetchEffect{
      source: Source,
      callback_source: nil,
      context: context(action),
      revision: make_ref()
    }
  end
end
