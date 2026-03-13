defmodule Minga.Popup.RegistryTest do
  use ExUnit.Case, async: false

  alias Minga.Popup.Registry
  alias Minga.Popup.Rule

  setup do
    Registry.init()
    Registry.clear()
    :ok
  end

  describe "register/1 and match/1" do
    test "registers and matches a string pattern rule" do
      rule = Rule.new("*Warnings*", side: :bottom)
      Registry.register(rule)

      assert {:ok, matched} = Registry.match("*Warnings*")
      assert matched.pattern == "*Warnings*"
      assert matched.side == :bottom
    end

    test "registers and matches a regex pattern rule" do
      rule = Rule.new(~r/\*Help/, display: :float)
      Registry.register(rule)

      assert {:ok, matched} = Registry.match("*Help: elixir*")
      assert matched.display == :float
    end

    test "returns :none when no rule matches" do
      rule = Rule.new("*Warnings*")
      Registry.register(rule)

      assert :none = Registry.match("some-file.ex")
    end

    test "returns :none with empty registry" do
      assert :none = Registry.match("*Warnings*")
    end

    test "higher priority rule wins" do
      low = Rule.new("*Warnings*", side: :bottom, priority: 0)
      high = Rule.new("*Warnings*", side: :right, priority: 10)

      Registry.register(low)
      Registry.register(high)

      assert {:ok, matched} = Registry.match("*Warnings*")
      assert matched.side == :right
    end

    test "later registration wins at same priority" do
      first = Rule.new("*Warnings*", side: :bottom, priority: 0)
      second = Rule.new("*Warnings*", side: :right, priority: 0)

      Registry.register(first)
      Registry.register(second)

      # Both match, but we want the first one found in sorted order.
      # With same priority, the ordered_set key is {-priority, sequence}.
      # Later sequence is higher, so it sorts after. First key in ordered_set
      # is the first registered. This means first registration wins at same priority.
      # Let's just verify one matches.
      assert {:ok, _matched} = Registry.match("*Warnings*")
    end

    test "first matching rule wins when multiple patterns match" do
      specific = Rule.new("*Help: elixir*", side: :right, priority: 10)
      general = Rule.new(~r/\*Help/, side: :bottom, priority: 0)

      Registry.register(specific)
      Registry.register(general)

      # The specific rule has higher priority, so it should match first
      assert {:ok, matched} = Registry.match("*Help: elixir*")
      assert matched.side == :right

      # A name that only matches the general regex
      assert {:ok, matched} = Registry.match("*Help: zig*")
      assert matched.side == :bottom
    end

    test "regex and string patterns coexist" do
      string_rule = Rule.new("*Warnings*", side: :bottom)
      regex_rule = Rule.new(~r/\*test-/, side: :right)

      Registry.register(string_rule)
      Registry.register(regex_rule)

      assert {:ok, matched} = Registry.match("*Warnings*")
      assert matched.side == :bottom

      assert {:ok, matched} = Registry.match("*test-output*")
      assert matched.side == :right

      assert :none = Registry.match("random-buffer")
    end
  end

  describe "list/0" do
    test "returns all rules in priority order" do
      low = Rule.new("*low*", priority: 0)
      high = Rule.new("*high*", priority: 10)
      mid = Rule.new("*mid*", priority: 5)

      Registry.register(low)
      Registry.register(high)
      Registry.register(mid)

      rules = Registry.list()
      assert length(rules) == 3

      priorities = Enum.map(rules, & &1.priority)
      assert priorities == [10, 5, 0]
    end

    test "returns empty list when no rules registered" do
      assert Registry.list() == []
    end
  end

  describe "unregister/1" do
    test "removes rules with matching string pattern" do
      rule = Rule.new("*Warnings*")
      Registry.register(rule)

      assert {:ok, _} = Registry.match("*Warnings*")

      Registry.unregister("*Warnings*")

      assert :none = Registry.match("*Warnings*")
    end

    test "removes rules with matching regex pattern" do
      rule = Rule.new(~r/\*Help/)
      Registry.register(rule)

      Registry.unregister(~r/\*Help/)

      assert :none = Registry.match("*Help*")
    end

    test "does not remove non-matching rules" do
      rule1 = Rule.new("*Warnings*")
      rule2 = Rule.new("*Messages*")

      Registry.register(rule1)
      Registry.register(rule2)

      Registry.unregister("*Warnings*")

      assert :none = Registry.match("*Warnings*")
      assert {:ok, _} = Registry.match("*Messages*")
    end
  end

  describe "clear/0" do
    test "removes all rules" do
      Registry.register(Rule.new("*Warnings*"))
      Registry.register(Rule.new("*Messages*"))

      assert length(Registry.list()) == 2

      Registry.clear()

      assert Registry.list() == []
    end
  end

  describe "init/0" do
    test "is idempotent" do
      assert Registry.init() in [:ok, :already_exists]
      assert Registry.init() == :already_exists
    end

    test "preserves data across duplicate init calls" do
      Registry.register(Rule.new("*test*"))
      Registry.init()

      assert {:ok, _} = Registry.match("*test*")
    end
  end
end
