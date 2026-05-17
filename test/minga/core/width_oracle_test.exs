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

    test "fingerprint changes when measurements change" do
      oracle = Measured.new()
      before_fp = WidthOracle.fingerprint(oracle)
      after_fp = oracle |> Measured.put_width("mmmm", 22) |> WidthOracle.fingerprint()

      refute before_fp == after_fp
      assert after_fp == {:measured, 1, :erlang.phash2(%{"mmmm" => 22})}
    end

    test "fingerprint distinguishes different initial cache contents" do
      fp1 = WidthOracle.fingerprint(Measured.new(%{"wide" => 50}))
      fp2 = WidthOracle.fingerprint(Measured.new(%{"narrow" => 7}))

      refute fp1 == fp2
      assert fp1 == {:measured, 0, :erlang.phash2(%{"wide" => 50})}
    end
  end
end
