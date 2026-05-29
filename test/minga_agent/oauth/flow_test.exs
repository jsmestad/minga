defmodule MingaAgent.OAuth.FlowTest do
  use ExUnit.Case, async: false

  describe "registration" do
    test "only one flow can register at a time" do
      Process.register(self(), :minga_oauth_flow)

      task =
        Task.async(fn ->
          case Process.whereis(:minga_oauth_flow) do
            nil -> :available
            _pid -> :already_running
          end
        end)

      assert Task.await(task) == :already_running
    after
      try do
        Process.unregister(:minga_oauth_flow)
      rescue
        ArgumentError -> :ok
      end
    end
  end
end
