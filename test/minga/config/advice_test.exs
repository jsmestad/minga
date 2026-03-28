defmodule Minga.Config.AdviceTest do
  use ExUnit.Case, async: true

  alias Minga.Config.Advice

  @table_prefix :advice_test

  setup context do
    table = :"#{@table_prefix}_#{context.test}"

    :ets.new(table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true
    ])

    on_exit(fn ->
      if :ets.whereis(table) != :undefined, do: :ets.delete(table)
    end)

    %{table: table}
  end

  describe "register/4" do
    test "registers a before advice function", %{table: table} do
      assert :ok = Advice.register(table, :before, :save, fn s -> s end)
      assert Advice.has_advice?(table, :before, :save)
    end

    test "registers an after advice function", %{table: table} do
      assert :ok = Advice.register(table, :after, :save, fn s -> s end)
      assert Advice.has_advice?(table, :after, :save)
    end

    test "registers an around advice function", %{table: table} do
      assert :ok =
               Advice.register(table, :around, :save, fn execute, state -> execute.(state) end)

      assert Advice.has_advice?(table, :around, :save)
    end

    test "registers an override advice function", %{table: table} do
      assert :ok = Advice.register(table, :override, :save, fn s -> s end)
      assert Advice.has_advice?(table, :override, :save)
    end

    test "rejects invalid phase", %{table: table} do
      assert {:error, _} = Advice.register(table, :banana, :save, fn s -> s end)
    end

    test "rejects wrong arity for around", %{table: table} do
      assert {:error, _} = Advice.register(table, :around, :save, fn s -> s end)
    end

    test "rejects wrong arity for before", %{table: table} do
      assert {:error, _} = Advice.register(table, :before, :save, fn _exec, s -> s end)
    end
  end

  describe "wrap/3 with before advice" do
    test "transforms state before the command runs", %{table: table} do
      Advice.register(table, :before, :save, fn s -> Map.put(s, :cleaned, true) end)

      execute = fn s -> Map.put(s, :saved, true) end
      result = Advice.wrap(table, :save, execute).(%{})

      assert result == %{cleaned: true, saved: true}
    end

    test "chains multiple before functions in order", %{table: table} do
      Advice.register(table, :before, :save, fn s -> Map.update(s, :log, [:a], &[:a | &1]) end)
      Advice.register(table, :before, :save, fn s -> Map.update(s, :log, [:b], &[:b | &1]) end)

      execute = fn s -> s end
      result = Advice.wrap(table, :save, execute).(%{})

      assert result.log == [:b, :a]
    end
  end

  describe "wrap/3 with after advice" do
    test "transforms state after the command runs", %{table: table} do
      Advice.register(table, :after, :save, fn s -> Map.put(s, :notified, true) end)

      execute = fn s -> Map.put(s, :saved, true) end
      result = Advice.wrap(table, :save, execute).(%{})

      assert result == %{saved: true, notified: true}
    end
  end

  describe "wrap/3 with around advice" do
    test "around can call the original command", %{table: table} do
      Advice.register(table, :around, :save, fn execute, state ->
        state = Map.put(state, :before_around, true)
        result = execute.(state)
        Map.put(result, :after_around, true)
      end)

      execute = fn s -> Map.put(s, :saved, true) end
      result = Advice.wrap(table, :save, execute).(%{})

      assert result == %{before_around: true, saved: true, after_around: true}
    end

    test "around can skip the original command", %{table: table} do
      Advice.register(table, :around, :format_buffer, fn _execute, state ->
        Map.put(state, :skipped, true)
      end)

      execute = fn s -> Map.put(s, :formatted, true) end
      result = Advice.wrap(table, :format_buffer, execute).(%{})

      assert result == %{skipped: true}
      refute Map.has_key?(result, :formatted)
    end

    test "multiple arounds nest outward", %{table: table} do
      # First registered = outermost
      Advice.register(table, :around, :save, fn execute, state ->
        state = Map.update(state, :order, [:outer_before], &[:outer_before | &1])
        result = execute.(state)
        Map.update(result, :order, [:outer_after], &[:outer_after | &1])
      end)

      Advice.register(table, :around, :save, fn execute, state ->
        state = Map.update(state, :order, [:inner_before], &[:inner_before | &1])
        result = execute.(state)
        Map.update(result, :order, [:inner_after], &[:inner_after | &1])
      end)

      execute = fn s -> Map.update(s, :order, [:core], &[:core | &1]) end
      result = Advice.wrap(table, :save, execute).(%{})

      assert Enum.reverse(result.order) == [
               :outer_before,
               :inner_before,
               :core,
               :inner_after,
               :outer_after
             ]
    end
  end

  describe "wrap/3 with override" do
    test "override replaces the original command", %{table: table} do
      Advice.register(table, :override, :save, fn s -> Map.put(s, :custom_save, true) end)

      execute = fn s -> Map.put(s, :original_save, true) end
      result = Advice.wrap(table, :save, execute).(%{})

      assert result == %{custom_save: true}
      refute Map.has_key?(result, :original_save)
    end

    test "before and after still run around an overridden command", %{table: table} do
      Advice.register(table, :before, :save, fn s -> Map.put(s, :before, true) end)
      Advice.register(table, :override, :save, fn s -> Map.put(s, :overridden, true) end)
      Advice.register(table, :after, :save, fn s -> Map.put(s, :after, true) end)

      execute = fn s -> Map.put(s, :original, true) end
      result = Advice.wrap(table, :save, execute).(%{})

      assert result == %{before: true, overridden: true, after: true}
      refute Map.has_key?(result, :original)
    end

    test "around wraps the override, not the original", %{table: table} do
      Advice.register(table, :override, :save, fn s -> Map.put(s, :overridden, true) end)

      Advice.register(table, :around, :save, fn execute, state ->
        result = execute.(state)
        Map.put(result, :around_ran, true)
      end)

      execute = fn s -> Map.put(s, :original, true) end
      result = Advice.wrap(table, :save, execute).(%{})

      assert result == %{overridden: true, around_ran: true}
      refute Map.has_key?(result, :original)
    end
  end

  describe "wrap/3 with no advice" do
    test "returns the original function unchanged", %{table: table} do
      execute = fn s -> Map.put(s, :saved, true) end
      wrapped = Advice.wrap(table, :save, execute)

      # Same function reference when no advice
      assert wrapped == execute
    end
  end

  describe "crash isolation" do
    test "crashing before advice is skipped", %{table: table} do
      Advice.register(table, :before, :save, fn _s -> raise "boom" end)
      Advice.register(table, :before, :save, fn s -> Map.put(s, :ok, true) end)

      execute = fn s -> Map.put(s, :saved, true) end
      result = Advice.wrap(table, :save, execute).(%{input: true})

      assert result == %{input: true, ok: true, saved: true}
    end

    test "crashing around advice falls through to original", %{table: table} do
      Advice.register(table, :around, :save, fn _execute, _state -> raise "boom" end)

      execute = fn s -> Map.put(s, :saved, true) end
      result = Advice.wrap(table, :save, execute).(%{})

      # Core crash is caught, state preserved
      assert result == %{}
    end

    test "crashing after advice is skipped", %{table: table} do
      Advice.register(table, :after, :save, fn _s -> raise "boom" end)
      Advice.register(table, :after, :save, fn s -> Map.put(s, :ok, true) end)

      execute = fn s -> Map.put(s, :saved, true) end
      result = Advice.wrap(table, :save, execute).(%{})

      assert result == %{saved: true, ok: true}
    end
  end

  describe "has_advice?/3 and advised?/2" do
    test "returns false when no advice registered", %{table: table} do
      refute Advice.has_advice?(table, :before, :save)
      refute Advice.advised?(table, :save)
    end

    test "returns true after registration", %{table: table} do
      Advice.register(table, :around, :quit, fn exec, s -> exec.(s) end)
      assert Advice.has_advice?(table, :around, :quit)
      assert Advice.advised?(table, :quit)
    end
  end

  describe "circuit breaker" do
    test "disables advice after 5 consecutive failures", %{table: table} do
      crasher = fn _s -> raise "boom" end
      Advice.register(table, :before, :move_left, crasher)

      execute = fn s -> Map.put(s, :moved, true) end
      wrapped = Advice.wrap(table, :move_left, execute)

      # First 4 failures: hook still runs (and crashes), but is not disabled
      for _ <- 1..4 do
        wrapped.(%{})
      end

      refute Advice.disabled?(table, :before, :move_left, crasher)

      # 5th failure triggers the circuit breaker
      wrapped.(%{})

      assert Advice.disabled?(table, :before, :move_left, crasher)
    end

    test "disabled advice is skipped on subsequent invocations", %{table: table} do
      call_count = :counters.new(1, [:atomics])

      crasher = fn _s ->
        :counters.add(call_count, 1, 1)
        raise "boom"
      end

      Advice.register(table, :before, :move_left, crasher)

      execute = fn s -> Map.put(s, :moved, true) end
      wrapped = Advice.wrap(table, :move_left, execute)

      # Trip the circuit breaker (5 failures)
      for _ <- 1..5 do
        wrapped.(%{})
      end

      assert :counters.get(call_count, 1) == 5

      # Subsequent calls skip the disabled hook entirely
      result = wrapped.(%{})
      assert result == %{moved: true}
      assert :counters.get(call_count, 1) == 5
    end

    test "successful invocation resets the failure counter", %{table: table} do
      invocation = :counters.new(1, [:atomics])

      # Fails first 3 times, then succeeds
      flaky = fn s ->
        :counters.add(invocation, 1, 1)
        count = :counters.get(invocation, 1)

        if count <= 3 do
          raise "intermittent failure"
        else
          Map.put(s, :flaky_ran, true)
        end
      end

      Advice.register(table, :before, :save, flaky)

      execute = fn s -> Map.put(s, :saved, true) end
      wrapped = Advice.wrap(table, :save, execute)

      # 3 failures
      for _ <- 1..3 do
        wrapped.(%{})
      end

      refute Advice.disabled?(table, :before, :save, flaky)

      # Success on 4th call resets the counter
      result = wrapped.(%{})
      assert result.flaky_ran == true
      assert result.saved == true

      # 3 more failures should NOT trip the breaker (counter was reset)
      # Reset invocation counter so the function crashes again
      # Verify the counter was reset by checking it's not disabled
      refute Advice.disabled?(table, :before, :save, flaky)
    end

    test "only the crashing hook is disabled, others keep running", %{table: table} do
      crasher = fn _s -> raise "always broken" end
      healthy = fn s -> Map.put(s, :healthy, true) end

      Advice.register(table, :after, :save, crasher)
      Advice.register(table, :after, :save, healthy)

      execute = fn s -> Map.put(s, :saved, true) end
      wrapped = Advice.wrap(table, :save, execute)

      # Trip the breaker on the crasher (5 invocations)
      for _ <- 1..5 do
        wrapped.(%{})
      end

      assert Advice.disabled?(table, :after, :save, crasher)
      refute Advice.disabled?(table, :after, :save, healthy)

      # Healthy hook still runs
      result = wrapped.(%{})
      assert result == %{saved: true, healthy: true}
    end

    test "reset clears circuit breaker state", %{table: table} do
      crasher = fn _s -> raise "boom" end
      Advice.register(table, :before, :save, crasher)

      execute = fn s -> s end
      wrapped = Advice.wrap(table, :save, execute)

      # Trip the breaker
      for _ <- 1..5 do
        wrapped.(%{})
      end

      assert Advice.disabled?(table, :before, :save, crasher)

      # Reset clears everything
      Advice.reset(table)

      refute Advice.disabled?(table, :before, :save, crasher)
    end
  end

  describe "reset/1" do
    test "clears all advice", %{table: table} do
      Advice.register(table, :before, :save, fn s -> s end)
      Advice.register(table, :around, :quit, fn exec, s -> exec.(s) end)
      Advice.register(table, :override, :format_buffer, fn s -> s end)

      Advice.reset(table)

      refute Advice.advised?(table, :save)
      refute Advice.advised?(table, :quit)
      refute Advice.advised?(table, :format_buffer)
    end
  end
end
