defmodule Minga.Core.WidthOracleTest do
  use ExUnit.Case, async: true

  alias Minga.Core.WidthOracle
  alias Minga.Core.WidthOracle.Measured
  alias Minga.Core.WidthOracle.Monospace

  describe "monospace oracle" do
    test "matches Unicode display widths" do
      oracle = %Monospace{}

      assert WidthOracle.grapheme_width(oracle, "a") == Minga.Core.Unicode.grapheme_width("a")

      assert WidthOracle.display_width(oracle, "hello") ==
               Minga.Core.Unicode.display_width("hello")
    end
  end

  describe "measured oracle" do
    test "dispatches on struct and uses cached widths" do
      oracle = Measured.new() |> Measured.put_width("mmmm", 22)

      assert WidthOracle.display_width(oracle, "mmmm") == 22
      assert WidthOracle.grapheme_width(oracle, "a") == 1
    end

    test "clears cached measurements" do
      oracle = Measured.new(%{"wide" => 50}) |> Measured.clear_cache()

      assert WidthOracle.display_width(oracle, "wide") == 4
    end
  end
end
