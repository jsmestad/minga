defmodule MingaEditor.Renderer.ObservedBuffersTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Renderer.ObservedBuffers

  test "reconcile preserves retained monitors and drops retired versions" do
    first = start_supervised!({Agent, fn -> :first end}, id: :observed_first)
    second = start_supervised!({Agent, fn -> :second end}, id: :observed_second)

    observed = ObservedBuffers.reconcile(ObservedBuffers.new(), MapSet.new([first, second]))
    first_ref = observed.monitors[first]
    second_ref = observed.monitors[second]

    assert is_reference(first_ref)
    assert is_reference(second_ref)
    assert monitored?(first)
    assert monitored?(second)

    observed =
      observed
      |> ObservedBuffers.record_version(first, 1)
      |> ObservedBuffers.record_version(second, 2)
      |> ObservedBuffers.reconcile(MapSet.new([second]))

    refute Map.has_key?(observed.monitors, first)
    refute Map.has_key?(observed.versions, first)
    refute monitored?(first)
    assert observed.monitors[second] == second_ref
    assert observed.versions == %{second => 2}

    assert MapSet.subset?(
             MapSet.new(Map.keys(observed.versions)),
             MapSet.new(Map.keys(observed.monitors))
           )
  end

  test "recorded and intent versions are constrained to monitored buffers" do
    monitored = start_supervised!({Agent, fn -> :monitored end}, id: :observed_monitored)
    unmonitored = start_supervised!({Agent, fn -> :unmonitored end}, id: :observed_unmonitored)

    observed =
      ObservedBuffers.new()
      |> ObservedBuffers.reconcile(MapSet.new([monitored]))
      |> ObservedBuffers.record_version(monitored, 3)
      |> ObservedBuffers.record_version(unmonitored, 4)

    assert ObservedBuffers.recorded_version(observed, monitored) == 3
    assert ObservedBuffers.recorded_version(observed, unmonitored) == nil
    assert observed.versions == %{monitored => 3}

    assert ObservedBuffers.monitored_versions(observed, %{monitored => 5, unmonitored => 6}) == %{
             monitored => 5
           }
  end

  test "drop_down ignores stale messages and removes only exact pid and ref matches" do
    first = start_supervised!({Agent, fn -> :first_down end}, id: :observed_first_down)
    second = start_supervised!({Agent, fn -> :second_down end}, id: :observed_second_down)

    observed =
      ObservedBuffers.new()
      |> ObservedBuffers.reconcile(MapSet.new([first, second]))
      |> ObservedBuffers.record_version(first, 1)
      |> ObservedBuffers.record_version(second, 2)

    first_ref = observed.monitors[first]
    second_ref = observed.monitors[second]

    wrong_ref =
      Process.monitor(start_supervised!({Agent, fn -> :wrong end}, id: :observed_wrong_down))

    assert {^observed, false} = ObservedBuffers.drop_down(observed, wrong_ref, first)
    assert {^observed, false} = ObservedBuffers.drop_down(observed, first_ref, second)

    assert {dropped, true} = ObservedBuffers.drop_down(observed, second_ref, second)
    refute Map.has_key?(dropped.monitors, second)
    refute Map.has_key?(dropped.versions, second)
    assert dropped.monitors == %{first => first_ref}
    assert dropped.versions == %{first => 1}

    Process.demonitor(wrong_ref, [:flush])
  end

  defp monitored?(pid) do
    {:monitors, monitors} = Process.info(self(), :monitors)
    {:process, pid} in monitors
  end
end
