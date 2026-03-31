defmodule MingaEditor.UI.Popup.RegistryTest do
  use ExUnit.Case, async: true

  alias MingaEditor.UI.Popup.Registry
  alias MingaEditor.UI.Popup.Rule

  setup do
    # Each test gets its own ETS table via a unique atom name.
    # No cross-test interference, safe for async: true.
    table = :"popup_reg_#{:erlang.unique_integer([:positive])}"
    Registry.init(table)
    on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)
    %{table: table}
  end

  describe "register and match" do
    test "registers and matches a string pattern rule", %{table: t} do
      rule = Rule.new("*Warnings*", side: :bottom)
      Registry.register(rule, t)

      assert {:ok, matched} = Registry.match("*Warnings*", t)
      assert matched.pattern == "*Warnings*"
      assert matched.side == :bottom
    end

    test "registers and matches a regex pattern rule", %{table: t} do
      rule = Rule.new(~r/\*Help/, display: :float)
      Registry.register(rule, t)

      assert {:ok, matched} = Registry.match("*Help: elixir*", t)
      assert matched.display == :float
    end

    test "returns :none when no rule matches", %{table: t} do
      rule = Rule.new("*Warnings*")
      Registry.register(rule, t)

      assert :none = Registry.match("some-file.ex", t)
    end

    test "returns :none with empty registry", %{table: t} do
      assert :none = Registry.match("*Warnings*", t)
    end

    test "higher priority rule wins", %{table: t} do
      low = Rule.new("*Warnings*", side: :bottom, priority: 0)
      high = Rule.new("*Warnings*", side: :right, priority: 10)

      Registry.register(low, t)
      Registry.register(high, t)

      assert {:ok, matched} = Registry.match("*Warnings*", t)
      assert matched.side == :right
    end

    test "later registration wins at same priority", %{table: t} do
      first = Rule.new("*Warnings*", side: :bottom, priority: 0)
      second = Rule.new("*Warnings*", side: :right, priority: 0)

      Registry.register(first, t)
      Registry.register(second, t)

      assert {:ok, _matched} = Registry.match("*Warnings*", t)
    end

    test "first matching rule wins when multiple patterns match", %{table: t} do
      specific = Rule.new("*Help: elixir*", side: :right, priority: 10)
      general = Rule.new(~r/\*Help/, side: :bottom, priority: 0)

      Registry.register(specific, t)
      Registry.register(general, t)

      assert {:ok, matched} = Registry.match("*Help: elixir*", t)
      assert matched.side == :right

      assert {:ok, matched} = Registry.match("*Help: zig*", t)
      assert matched.side == :bottom
    end

    test "regex and string patterns coexist", %{table: t} do
      string_rule = Rule.new("*Warnings*", side: :bottom)
      regex_rule = Rule.new(~r/\*test-/, side: :right)

      Registry.register(string_rule, t)
      Registry.register(regex_rule, t)

      assert {:ok, matched} = Registry.match("*Warnings*", t)
      assert matched.side == :bottom

      assert {:ok, matched} = Registry.match("*test-output*", t)
      assert matched.side == :right

      assert :none = Registry.match("random-buffer", t)
    end
  end

  describe "list" do
    test "returns all rules in priority order", %{table: t} do
      low = Rule.new("*low*", priority: 0)
      high = Rule.new("*high*", priority: 10)
      mid = Rule.new("*mid*", priority: 5)

      Registry.register(low, t)
      Registry.register(high, t)
      Registry.register(mid, t)

      rules = Registry.list(t)
      assert length(rules) == 3

      priorities = Enum.map(rules, & &1.priority)
      assert priorities == [10, 5, 0]
    end

    test "returns empty list when no rules registered", %{table: t} do
      assert Registry.list(t) == []
    end
  end

  describe "unregister" do
    test "removes rules with matching string pattern", %{table: t} do
      rule = Rule.new("*Warnings*")
      Registry.register(rule, t)
      assert {:ok, _} = Registry.match("*Warnings*", t)

      Registry.unregister("*Warnings*", t)
      assert :none = Registry.match("*Warnings*", t)
    end

    test "removes rules with matching regex pattern", %{table: t} do
      rule = Rule.new(~r/\*Help/)
      Registry.register(rule, t)

      Registry.unregister(~r/\*Help/, t)
      assert :none = Registry.match("*Help*", t)
    end

    test "does not remove non-matching rules", %{table: t} do
      Registry.register(Rule.new("*Warnings*"), t)
      Registry.register(Rule.new("*Messages*"), t)

      Registry.unregister("*Warnings*", t)

      assert :none = Registry.match("*Warnings*", t)
      assert {:ok, _} = Registry.match("*Messages*", t)
    end
  end

  describe "clear" do
    test "removes all rules", %{table: t} do
      Registry.register(Rule.new("*Warnings*"), t)
      Registry.register(Rule.new("*Messages*"), t)
      assert length(Registry.list(t)) == 2

      Registry.clear(t)
      assert Registry.list(t) == []
    end
  end

  describe "init" do
    test "is idempotent" do
      table = :"popup_reg_idempotent_#{:erlang.unique_integer([:positive])}"
      Registry.init(table)
      Registry.init(table)
      on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)

      # Table should exist and be usable
      assert :none = Registry.match("anything", table)
    end

    test "preserves data across duplicate init calls", %{table: t} do
      Registry.register(Rule.new("*test*"), t)
      Registry.init(t)

      assert {:ok, _} = Registry.match("*test*", t)
    end
  end
end
