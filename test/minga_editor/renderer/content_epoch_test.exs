defmodule MingaEditor.Renderer.ContentEpochTest do
  # Exercises the VM-global persistent counter during concurrent first installation.
  use ExUnit.Case, async: false

  alias MingaEditor.Renderer.ContentEpoch

  @counter_key {ContentEpoch, :counter}

  setup do
    previous_counter = :persistent_term.get(@counter_key, nil)
    # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
    :persistent_term.erase(@counter_key)

    on_exit(fn -> restore_counter(previous_counter) end)
  end

  test "concurrent first allocations remain unique" do
    parent = self()

    tasks =
      for _index <- 1..256 do
        Task.async(fn ->
          send(parent, {:allocator_ready, self()})
          receive do: (:allocate -> ContentEpoch.next())
        end)
      end

    task_pids =
      Enum.map(tasks, fn _task ->
        assert_receive {:allocator_ready, task_pid}, 5_000
        task_pid
      end)

    Enum.each(task_pids, &send(&1, :allocate))
    epochs = Task.await_many(tasks, 5_000)

    assert Enum.all?(epochs, &is_integer/1)
    assert MapSet.size(MapSet.new(epochs)) == length(epochs)
  end

  # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
  defp restore_counter(nil), do: :persistent_term.erase(@counter_key)

  # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
  defp restore_counter(counter), do: :persistent_term.put(@counter_key, counter)
end
