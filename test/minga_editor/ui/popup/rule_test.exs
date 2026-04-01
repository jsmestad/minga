defmodule MingaEditor.UI.Popup.RuleTest do
  use ExUnit.Case, async: true

  alias Minga.Popup.Rule

  describe "new/2" do
    test "creates a rule with string pattern and defaults" do
      rule = Rule.new("*Warnings*")

      assert rule.pattern == "*Warnings*"
      assert rule.display == :split
      assert rule.side == :bottom
      assert rule.size == {:percent, 30}
      assert rule.focus == true
      assert rule.auto_close == false
      assert rule.quit_key == "q"
      assert rule.modeline == false
      assert rule.priority == 0
    end

    test "creates a rule with regex pattern" do
      rule = Rule.new(~r/\*Help/)

      assert %Regex{} = rule.pattern
      assert rule.pattern.source == "\\*Help"
      assert rule.display == :split
    end

    test "accepts all split options" do
      rule =
        Rule.new("*test*",
          display: :split,
          side: :right,
          size: {:cols, 40},
          focus: false,
          auto_close: true,
          quit_key: "x",
          modeline: true,
          priority: 10
        )

      assert rule.side == :right
      assert rule.size == {:cols, 40}
      assert rule.focus == false
      assert rule.auto_close == true
      assert rule.quit_key == "x"
      assert rule.modeline == true
      assert rule.priority == 10
    end

    test "accepts all float options" do
      rule =
        Rule.new("*help*",
          display: :float,
          width: {:percent, 60},
          height: {:percent, 70},
          position: :center,
          border: :rounded,
          focus: true,
          auto_close: true
        )

      assert rule.display == :float
      assert rule.width == {:percent, 60}
      assert rule.height == {:percent, 70}
      assert rule.position == :center
      assert rule.border == :rounded
    end

    test "accepts offset position for float" do
      rule = Rule.new("*test*", display: :float, position: {:offset, -5, 10})

      assert rule.position == {:offset, -5, 10}
    end

    test "accepts all side values" do
      for side <- [:bottom, :right, :left, :top] do
        rule = Rule.new("*test*", side: side)
        assert rule.side == side
      end
    end

    test "accepts all border styles" do
      for border <- [:rounded, :single, :double, :none] do
        rule = Rule.new("*test*", display: :float, border: border)
        assert rule.border == border
      end
    end

    test "accepts rows size" do
      rule = Rule.new("*test*", size: {:rows, 10})
      assert rule.size == {:rows, 10}
    end

    test "accepts percent size" do
      rule = Rule.new("*test*", size: {:percent, 50})
      assert rule.size == {:percent, 50}
    end

    test "raises on invalid display mode" do
      assert_raise ArgumentError, fn ->
        Rule.new("*test*", display: :overlay)
      end
    end

    test "raises on invalid side" do
      assert_raise ArgumentError, fn ->
        Rule.new("*test*", side: :center)
      end
    end

    test "raises on invalid size tuple" do
      assert_raise ArgumentError, fn ->
        Rule.new("*test*", size: {:pixels, 100})
      end
    end

    test "raises on percent out of range" do
      assert_raise ArgumentError, fn ->
        Rule.new("*test*", size: {:percent, 0})
      end

      assert_raise ArgumentError, fn ->
        Rule.new("*test*", size: {:percent, 101})
      end
    end

    test "raises on zero rows" do
      assert_raise ArgumentError, fn ->
        Rule.new("*test*", size: {:rows, 0})
      end
    end

    test "raises on unknown option key" do
      assert_raise ArgumentError, fn ->
        Rule.new("*test*", unknown: true)
      end
    end

    test "raises on invalid border style" do
      assert_raise ArgumentError, fn ->
        Rule.new("*test*", border: :fancy)
      end
    end

    test "raises on non-boolean focus" do
      assert_raise ArgumentError, fn ->
        Rule.new("*test*", focus: "yes")
      end
    end
  end

  describe "matches?/2" do
    test "string pattern matches exactly" do
      rule = Rule.new("*Warnings*")

      assert Rule.matches?(rule, "*Warnings*")
      refute Rule.matches?(rule, "*warnings*")
      refute Rule.matches?(rule, "*Warnings")
      refute Rule.matches?(rule, "Warnings")
    end

    test "regex pattern matches anywhere in name" do
      rule = Rule.new(~r/\*Help/)

      assert Rule.matches?(rule, "*Help*")
      assert Rule.matches?(rule, "*Help: elixir*")
      refute Rule.matches?(rule, "*help*")
    end

    test "case-insensitive regex" do
      rule = Rule.new(~r/\*help/i)

      assert Rule.matches?(rule, "*Help*")
      assert Rule.matches?(rule, "*HELP*")
      assert Rule.matches?(rule, "*help*")
    end

    test "regex with anchors" do
      rule = Rule.new(~r/^\*grep/)

      assert Rule.matches?(rule, "*grep: pattern*")
      refute Rule.matches?(rule, "not *grep*")
    end
  end
end
