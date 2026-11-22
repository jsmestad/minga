defmodule Minga.Keymap.Scope.RegistryTest do
  # Writes go to the application-wide scope registry.
  # Every test uses unique scope names and asserts only on those names, so async modules cannot interfere.
  use ExUnit.Case, async: true

  alias Minga.Keymap.Scope

  @workers 64
  @rounds 5

  test "concurrent registrations and removals from many processes never lose an update" do
    for round <- 1..@rounds do
      prefix = "scope_conc_#{System.unique_integer([:positive])}_#{round}_"
      names = for i <- 1..@workers, do: {i, String.to_atom(prefix <> Integer.to_string(i))}
      on_exit(fn -> Enum.each(names, fn {_i, name} -> Scope.unregister(name) end) end)

      run_concurrently(names, fn {i, name} ->
        source = {:extension, name}
        :ok = Scope.register(source, name, Scope.Editor)

        case rem(i, 4) do
          1 -> :ok = Scope.unregister(name)
          3 -> :ok = Scope.unregister_source(source)
          _keep -> :ok
        end
      end)

      expected = for {i, name} <- names, rem(i, 2) == 0, into: MapSet.new(), do: name

      registered =
        Scope.all_scopes()
        |> Enum.filter(&String.starts_with?(Atom.to_string(&1), prefix))
        |> MapSet.new()

      assert registered == expected
      assert Enum.all?(expected, &(Scope.module_for(&1) == Scope.Editor))
      assert Scope.module_for(:editor) == Scope.Editor
    end
  end

  test "a source re-registering its own scope succeeds while another source is rejected" do
    name = :"scope_owner_#{System.unique_integer([:positive])}"
    source = {:extension, name}
    on_exit(fn -> Scope.unregister(name) end)

    assert :ok = Scope.register(source, name, Scope.Editor)
    assert :ok = Scope.register(source, name, Scope.Agent)
    assert Scope.module_for(name) == Scope.Agent

    assert {:error, {:duplicate_scope, ^name, ^source, {:extension, :other}}} =
             Scope.register({:extension, :other}, name, Scope.Editor)

    assert Scope.module_for(name) == Scope.Agent
  end

  @spec run_concurrently([term()], (term() -> :ok)) :: :ok
  defp run_concurrently(items, fun) do
    parent = self()

    tasks =
      Enum.map(items, fn item ->
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> fun.(item)
          end
        end)
      end)

    Enum.each(tasks, fn %Task{pid: pid} -> assert_receive {:ready, ^pid} end)
    Enum.each(tasks, fn %Task{pid: pid} -> send(pid, :go) end)
    Enum.each(tasks, &Task.await(&1, 10_000))
  end
end
