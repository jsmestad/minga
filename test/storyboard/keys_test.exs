defmodule Minga.Storyboard.KeysTest do
  @moduledoc "The inventory's key notation parses into key presses, and prose exits are refused."

  use ExUnit.Case, async: true

  alias Minga.Test.Storyboard.Keys

  @moduletag :storyboard

  test "named keys, chords and plain characters" do
    assert Keys.parse("SPC a a") == {:ok, [{:key, 32, 0}, {:key, ?a, 0}, {:key, ?a, 0}]}
    assert Keys.parse("esc") == {:ok, [{:key, 27, 0}]}
    assert Keys.parse("↩") == {:ok, [{:key, 13, 0}]}
    assert Keys.parse("⌃.") == {:ok, [{:key, ?., 0x02}]}
    assert Keys.parse("⌃\\ ⌃N") == {:ok, [{:key, ?\\, 0x02}, {:key, ?N, 0x02}]}
    assert Keys.parse("]h") == {:ok, [{:key, ?], 0}, {:key, ?h, 0}]}
    assert Keys.parse("SPC (pause)") == {:ok, [{:key, 32, 0}, :pause]}
    assert Keys.parse("SPC /") == {:ok, [{:key, 32, 0}, {:key, ?/, 0}]}
    assert Keys.parse(":") == {:ok, [{:key, ?:, 0}]}
  end

  test "exits that are not one key path" do
    for notation <- [
          "",
          "any key",
          "1-9",
          ":checkhealth",
          "(reconnected)",
          "]] / [[",
          "↩ on a failed block (Normal)",
          "⌘. or SPC a s"
        ] do
      assert Keys.parse(notation) == :not_a_key_path, "#{inspect(notation)} should not parse"
    end
  end

  test "format writes steps back in notation that parses to the same keys" do
    for notation <- ["SPC a a", "esc", "⌃.", "SPC (pause)", "SPC TAB d"] do
      assert notation |> Keys.parse!() |> Keys.format() == notation
    end

    steps = Keys.parse!("]h")
    assert Keys.format(steps) == "] h"
    assert Keys.parse!(Keys.format(steps)) == steps
  end
end
