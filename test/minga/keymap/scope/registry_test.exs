defmodule Minga.Keymap.Scope.RegistryTest do
  # Mutates the application-wide keymap scope registry, which other async tests read in full
  # (for example FocusOwnerTest checks every registered scope); the concurrency comes from tasks inside each test.
  use ExUnit.Case, async: false

  alias Minga.Keymap.Scope
  alias Minga.Keymap.Scope.Registry, as: ScopeRegistry

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

  test "every snapshot read during concurrent lifecycle operations is internally coherent" do
    prefix = "scope_cohere_#{System.unique_integer([:positive])}_"
    scope_count = 32
    names = for i <- 1..scope_count, do: String.to_atom(prefix <> Integer.to_string(i))
    on_exit(fn -> Enum.each(names, &Scope.unregister/1) end)

    # Flag to stop the reader once writers finish.
    flag = :atomics.new(1, [])
    incoherent = :atomics.new(1, [])

    reader =
      Task.async(fn ->
        read_count = do_coherence_reads(flag, incoherent, 0)
        {read_count, :atomics.get(incoherent, 1)}
      end)

    # Writers: register, re-register with a different module, then half unregister.
    writer_items = Enum.with_index(names)

    run_concurrently(writer_items, fn {name, idx} ->
      source = {:extension, name}
      :ok = Scope.register(source, name, Scope.Editor)
      :ok = Scope.register(source, name, Scope.Agent)

      if rem(idx, 2) == 0 do
        :ok = Scope.unregister_source(source)
      end
    end)

    :atomics.put(flag, 1, 1)
    {read_count, incoherent_count} = Task.await(reader, 10_000)

    assert incoherent_count == 0,
           "#{incoherent_count} incoherent snapshots observed out of #{read_count} reads"

    assert read_count > 0, "reader must have observed at least one snapshot"
  end

  test "unregister_source removes only the target and preserves every other source" do
    prefix = "scope_isolation_#{System.unique_integer([:positive])}_"

    source_a = {:extension, :isolation_a}
    source_b = {:extension, :isolation_b}
    name_a = :"#{prefix}a"
    name_b = :"#{prefix}b"

    on_exit(fn ->
      Scope.unregister(name_a)
      Scope.unregister(name_b)
    end)

    :ok = Scope.register(source_a, name_a, Scope.Editor)
    :ok = Scope.register(source_b, name_b, Scope.Agent)

    snapshot_before = ScopeRegistry.snapshot()
    assert snapshot_before.modules[name_a] == Scope.Editor
    assert snapshot_before.modules[name_b] == Scope.Agent
    assert snapshot_before.sources[name_a] == source_a
    assert snapshot_before.sources[name_b] == source_b

    :ok = Scope.unregister_source(source_a)

    snapshot_after = ScopeRegistry.snapshot()
    refute Map.has_key?(snapshot_after.modules, name_a)
    refute Map.has_key?(snapshot_after.sources, name_a)
    assert snapshot_after.modules[name_b] == Scope.Agent
    assert snapshot_after.sources[name_b] == source_b

    # Built-ins remain untouched.
    assert snapshot_after.modules[:editor] == Scope.Editor
    assert snapshot_after.sources[:editor] == :builtin
  end

  test "resolve_key returns a valid result or :not_found during concurrent scope churn" do
    prefix = "scope_resolve_#{System.unique_integer([:positive])}_"
    name = :"#{prefix}churn"
    source = {:extension, name}
    on_exit(fn -> Scope.unregister(name) end)

    flag = :atomics.new(1, [])
    invalid = :atomics.new(1, [])

    # Reader: resolve a key through the churning scope.
    reader =
      Task.async(fn ->
        do_resolution_reads(name, flag, invalid, 0)
      end)

    # Writer: register and unregister the scope repeatedly.
    churn_rounds = 200

    for _ <- 1..churn_rounds do
      :ok = Scope.register(source, name, Scope.Editor)
      :ok = Scope.unregister(name)
    end

    # Leave it registered so the reader can observe at least one hit.
    :ok = Scope.register(source, name, Scope.Editor)
    :atomics.put(flag, 1, 1)

    {read_count, invalid_count} = Task.await(reader, 10_000)

    assert invalid_count == 0,
           "#{invalid_count} invalid resolution results out of #{read_count} reads"

    assert read_count > 0
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  @spec do_coherence_reads(:atomics.atomics_ref(), :atomics.atomics_ref(), non_neg_integer()) ::
          non_neg_integer()
  defp do_coherence_reads(flag, incoherent, count) do
    if :atomics.get(flag, 1) == 1 do
      count
    else
      snapshot = ScopeRegistry.snapshot()

      unless MapSet.new(Map.keys(snapshot.modules)) == MapSet.new(Map.keys(snapshot.sources)) do
        :atomics.add(incoherent, 1, 1)
      end

      do_coherence_reads(flag, incoherent, count + 1)
    end
  end

  @spec do_resolution_reads(
          Scope.scope_name(),
          :atomics.atomics_ref(),
          :atomics.atomics_ref(),
          non_neg_integer()
        ) :: {non_neg_integer(), non_neg_integer()}
  defp do_resolution_reads(name, flag, invalid, count) do
    if :atomics.get(flag, 1) == 1 do
      {count, :atomics.get(invalid, 1)}
    else
      result = Scope.resolve_key(name, :normal, {?j, 0})

      case result do
        :not_found -> :ok
        {:command, _cmd} -> :ok
        {:prefix, _node} -> :ok
        _unexpected -> :atomics.add(invalid, 1, 1)
      end

      do_resolution_reads(name, flag, invalid, count + 1)
    end
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
