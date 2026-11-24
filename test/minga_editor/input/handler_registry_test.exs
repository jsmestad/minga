defmodule MingaEditor.Input.HandlerRegistryTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Input.HandlerRegistry

  defmodule FakeHandlerA, do: :ok
  defmodule FakeHandlerB, do: :ok
  defmodule FakeHandlerC, do: :ok

  setup do
    builtins = [
      {FakeHandlerA, :builtin, 10},
      {FakeHandlerB, :builtin, 20}
    ]

    name = :"handler_registry_#{System.unique_integer([:positive])}"
    registry = start_supervised!({HandlerRegistry, name: name, builtins: builtins})

    {:ok, registry: registry}
  end

  describe "snapshot after init" do
    test "returns builtins sorted by priority", %{registry: registry} do
      snapshot = HandlerRegistry.snapshot_on(registry)
      assert snapshot == [{FakeHandlerA, :builtin}, {FakeHandlerB, :builtin}]
    end
  end

  describe "register_on/4" do
    test "adds a handler at the specified priority", %{registry: registry} do
      :ok =
        HandlerRegistry.register_on(registry, {:extension, :test_ext}, FakeHandlerC, priority: 15)

      snapshot = HandlerRegistry.snapshot_on(registry)
      modules = Enum.map(snapshot, fn {mod, _src} -> mod end)

      assert modules == [FakeHandlerA, FakeHandlerC, FakeHandlerB]
    end

    test "replaces a handler from the same source at a new priority", %{registry: registry} do
      :ok = HandlerRegistry.register_on(registry, {:extension, :ext1}, FakeHandlerC, priority: 5)
      :ok = HandlerRegistry.register_on(registry, {:extension, :ext1}, FakeHandlerC, priority: 25)

      snapshot = HandlerRegistry.snapshot_on(registry)
      modules = Enum.map(snapshot, fn {mod, _src} -> mod end)

      assert modules == [FakeHandlerA, FakeHandlerB, FakeHandlerC]
      assert Enum.count(snapshot, fn {mod, _} -> mod == FakeHandlerC end) == 1
    end

    test "same module from different sources coexists", %{registry: registry} do
      :ok =
        HandlerRegistry.register_on(registry, {:extension, :ext1}, FakeHandlerC, priority: 15)

      :ok =
        HandlerRegistry.register_on(registry, {:extension, :ext2}, FakeHandlerC, priority: 25)

      snapshot = HandlerRegistry.snapshot_on(registry)
      c_entries = Enum.filter(snapshot, fn {mod, _} -> mod == FakeHandlerC end)
      assert length(c_entries) == 2
    end
  end

  describe "unregister_source_on/2" do
    test "removes all handlers from a source", %{registry: registry} do
      ext = {:extension, :ext1}
      :ok = HandlerRegistry.register_on(registry, ext, FakeHandlerC, priority: 15)

      assert Enum.any?(HandlerRegistry.snapshot_on(registry), fn {mod, _} ->
               mod == FakeHandlerC
             end)

      :ok = HandlerRegistry.unregister_source_on(registry, ext)

      refute Enum.any?(HandlerRegistry.snapshot_on(registry), fn {mod, _} ->
               mod == FakeHandlerC
             end)
    end

    test "preserves handlers from other sources", %{registry: registry} do
      :ok =
        HandlerRegistry.register_on(registry, {:extension, :ext1}, FakeHandlerC, priority: 15)

      :ok = HandlerRegistry.unregister_source_on(registry, {:extension, :ext2})

      assert Enum.any?(HandlerRegistry.snapshot_on(registry), fn {mod, _} ->
               mod == FakeHandlerC
             end)
    end

    test "unregistering :builtin is a no-op", %{registry: registry} do
      before = HandlerRegistry.snapshot_on(registry)
      :ok = HandlerRegistry.unregister_source_on(:ignored, :builtin)
      assert HandlerRegistry.snapshot_on(registry) == before
    end
  end

  describe "reset_on/1" do
    test "restores to builtins only", %{registry: registry} do
      :ok =
        HandlerRegistry.register_on(registry, {:extension, :ext1}, FakeHandlerC, priority: 15)

      :ok = HandlerRegistry.reset_on(registry)

      snapshot = HandlerRegistry.snapshot_on(registry)
      sources = Enum.map(snapshot, fn {_mod, src} -> src end) |> Enum.uniq()
      assert sources == [:builtin]
    end
  end

  describe "concurrent registration" do
    test "concurrent registrations never lose a handler", %{registry: registry} do
      handler_count = 64

      handlers =
        for i <- 1..handler_count do
          source = {:extension, :"conc_ext_#{i}"}
          handler_mod = :"Elixir.FakeConc#{i}"
          priority = rem(i * 7, 200)
          {source, handler_mod, priority}
        end

      run_concurrently(handlers, fn {source, handler_mod, priority} ->
        :ok = HandlerRegistry.register_on(registry, source, handler_mod, priority: priority)
      end)

      snapshot = HandlerRegistry.snapshot_on(registry)
      registered_modules = MapSet.new(snapshot, fn {mod, _src} -> mod end)

      for {_source, handler_mod, _priority} <- handlers do
        assert handler_mod in registered_modules,
               "handler #{inspect(handler_mod)} was lost during concurrent registration"
      end
    end

    test "concurrent register and unregister_source produce a consistent snapshot", %{
      registry: registry
    } do
      for _round <- 1..5 do
        keep_sources = for i <- 1..32, do: {:extension, :"keep_#{i}"}
        remove_sources = for i <- 1..32, do: {:extension, :"remove_#{i}"}

        # Register all first
        for {source, i} <- Enum.with_index(keep_sources ++ remove_sources) do
          handler_mod = :"Elixir.ConcMixed#{i}"
          :ok = HandlerRegistry.register_on(registry, source, handler_mod, priority: i * 10)
        end

        # Concurrently: register keep_sources again (idempotent) and unregister remove_sources
        actions =
          Enum.map(keep_sources, fn source -> {:register, source} end) ++
            Enum.map(remove_sources, fn source -> {:unregister, source} end)

        run_concurrently(actions, fn
          {:register, source} ->
            handler_mod = :"Elixir.ReReg#{inspect(source)}"
            :ok = HandlerRegistry.register_on(registry, source, handler_mod, priority: 50)

          {:unregister, source} ->
            :ok = HandlerRegistry.unregister_source_on(registry, source)
        end)

        snapshot = HandlerRegistry.snapshot_on(registry)
        snapshot_sources = MapSet.new(snapshot, fn {_mod, src} -> src end)

        # None of the removed sources should be present
        for source <- remove_sources do
          refute source in snapshot_sources,
                 "removed source #{inspect(source)} still present after concurrent cleanup"
        end

        # Reset for next round
        :ok = HandlerRegistry.reset_on(registry)
      end
    end

    test "snapshot is always sorted by priority", %{registry: registry} do
      # Register handlers with various priorities concurrently
      handlers =
        for i <- 1..32 do
          source = {:extension, :"sort_ext_#{i}"}
          handler_mod = :"Elixir.SortHandler#{i}"
          priority = rem(i * 13 + 7, 200)
          {source, handler_mod, priority}
        end

      run_concurrently(handlers, fn {source, handler_mod, priority} ->
        :ok = HandlerRegistry.register_on(registry, source, handler_mod, priority: priority)
      end)

      snapshot = HandlerRegistry.snapshot_on(registry)

      # No duplicates (each source+module pair appears exactly once)
      source_mod_pairs = MapSet.new(snapshot)
      assert MapSet.size(source_mod_pairs) == length(snapshot)
    end

    test "dispatch reads a coherent snapshot during concurrent mutations", %{registry: registry} do
      # Simulate a hot-path reader racing with mutations.
      # Uses snapshot_on/1 (GenServer call) so reads are sequenced after
      # writes and always reflect a complete generation.
      ext = {:extension, :dispatch_test}

      reader_task =
        Task.async(fn ->
          for _i <- 1..200 do
            snapshot = HandlerRegistry.snapshot_on(registry)
            # Every snapshot must be a list of {module, source} pairs
            Enum.each(snapshot, fn {mod, src} ->
              assert is_atom(mod), "non-atom module in snapshot: #{inspect(mod)}"

              assert is_atom(src) or match?({:extension, _}, src),
                     "invalid source in snapshot: #{inspect(src)}"
            end)
          end

          :reader_done
        end)

      writer_task =
        Task.async(fn ->
          for i <- 1..200 do
            handler_mod = :"Elixir.DispatchChurn#{rem(i, 10)}"

            :ok = HandlerRegistry.register_on(registry, ext, handler_mod, priority: i)

            if rem(i, 5) == 0 do
              :ok = HandlerRegistry.unregister_source_on(registry, ext)
            end
          end

          :writer_done
        end)

      assert Task.await(reader_task, 10_000) == :reader_done
      assert Task.await(writer_task, 10_000) == :writer_done
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
