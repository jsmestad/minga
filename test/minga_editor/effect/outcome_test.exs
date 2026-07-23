defmodule MingaEditor.Effect.OutcomeTest do
  use ExUnit.Case, async: true

  alias Minga.Test.EffectProbe
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.State.OperationQueue

  defp request do
    EffectProbe.request(self(), :outcome, :outcome_resource, Policy.fifo(1), {:return, :ok})
  end

  test "queued stores scheduler queue metadata as the single value payload" do
    request = request()

    assert %Outcome{request: ^request, value: {:queued, %OperationQueue{position: 2, total: 3}}} =
             Outcome.queued(request, 2, 3)
  end

  test "queued rejects invalid queue metadata through OperationQueue" do
    request = request()

    for {position, total} <- [{0, 1}, {1, 0}, {3, 2}, {1, 65_536}] do
      assert_raise ArgumentError, "invalid operation queue range", fn ->
        Outcome.queued(request, position, total)
      end
    end
  end

  test "constructors expose only locked value variants" do
    request = request()

    assert %Outcome{request: ^request, value: :running} = Outcome.running(request)

    assert %Outcome{request: ^request, value: {:completed, :result}} =
             Outcome.completed(request, :result)

    assert %Outcome{request: ^request, value: {:failed, :reason}} =
             Outcome.failed(request, :reason)

    assert %Outcome{request: ^request, value: {:canceled, :requested}} =
             Outcome.canceled(request, :requested)
  end

  test "stale keeps request identity and drops prior terminal payload" do
    request = request()

    stale = request |> Outcome.completed(:secret_result) |> Outcome.stale(:late)

    assert %Outcome{request: ^request, value: {:stale, :late}} = stale
    assert Map.from_struct(stale) |> Map.keys() |> Enum.sort() == [:request, :value]
  end

  test "terminal predicate follows value variants" do
    request = request()

    refute Outcome.terminal?(Outcome.queued(request, 1, 1))
    refute Outcome.terminal?(Outcome.running(request))
    assert Outcome.terminal?(Outcome.completed(request, :ok))
    assert Outcome.terminal?(Outcome.failed(request, :error))
    assert Outcome.terminal?(Outcome.canceled(request, :requested))
    assert Outcome.terminal?(Outcome.stale(Outcome.completed(request, :ok), :late))
  end
end
