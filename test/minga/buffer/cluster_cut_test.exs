defmodule Minga.Buffer.ClusterCutTest do
  use ExUnit.Case, async: true
  alias Minga.Buffer.UndoPatch

  # Every change must start and end on a grapheme cluster boundary of the text it applies to.
  defp bad_cuts(old, new) do
    cuts = fn text ->
      text
      |> String.graphemes()
      |> Enum.scan(0, &(byte_size(&1) + &2))
      |> MapSet.new()
      |> MapSet.put(0)
    end

    old_cuts = cuts.(old)
    new_cuts = cuts.(new)
    changes = UndoPatch.segment_changes(0, old, new, false)

    for {at, removed, inserted} <- changes,
        not (MapSet.member?(old_cuts, at) and MapSet.member?(old_cuts, at + byte_size(removed)) and
               MapSet.member?(new_cuts, at) and MapSet.member?(new_cuts, at + byte_size(inserted))) do
      {at, removed, inserted}
    end
  end

  for {name, pre, tail} <- [
        {"short line, short tail", "ab ", " z"},
        {"long CJK before, misaligned CJK tail", String.duplicate("語", 100),
         "a" <> String.duplicate("語", 40)},
        {"short before, misaligned CJK tail", "ab ", "a" <> String.duplicate("語", 40)},
        {"long CJK before (misaligned start), short tail", "a" <> String.duplicate("語", 100),
         " z"},
        {"long CJK before (aligned), short tail", String.duplicate("語", 100), " z"}
      ] do
    test "family emoji stays whole: #{name}" do
      old = unquote(pre) <> "👨‍👩‍👧" <> unquote(tail)
      new = unquote(pre) <> "👨‍👩‍👦" <> unquote(tail)
      assert bad_cuts(old, new) == []
    end
  end

  test "flags: a run of regional indicators longer than the lookback" do
    pre = String.duplicate("🇩🇪", 40)
    assert bad_cuts(pre <> "🇫🇷" <> " tail", pre <> "🇫🇮" <> " tail") == []
  end

  test "flags: an odd lookback start inside the run" do
    pre = "x" <> String.duplicate("🇩🇪", 33)
    assert bad_cuts(pre <> "🇫🇷" <> " tail", pre <> "🇫🇮" <> " tail") == []
  end

  test "combining mark after a long line" do
    pre = String.duplicate("語", 100)

    assert bad_cuts(
             pre <> "é" <> "a" <> String.duplicate("語", 40),
             pre <> "è" <> "a" <> String.duplicate("語", 40)
           ) == []
  end
end
