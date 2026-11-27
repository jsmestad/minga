defmodule Minga.Buffer.KeptReviewProofTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.KeptReview.{Proof, Source}

  test "opposite staged orders each prove only the newly included bytes" do
    source = splice(:insert, 1, 1, "", "XY")

    for {parent, child, from, to} <- [
          {"ab", "aXb", 0, 1},
          {"aXb", "aXYb", 1, 2},
          {"ab", "aYb", 1, 2},
          {"aYb", "aXYb", 0, 1}
        ] do
      assert Proof.included("aXYb", [source], parent, child) == [{:insert, 1, from, to}]
    end

    assert Proof.included("aXYb", [source], "aXYb", "azXYb") == []
  end

  test "a large unambiguous insertion does not require a quadratic alignment band" do
    prefix = String.duplicate("a", 10_240) <> "L"
    bytes = String.duplicate("X", 128)
    parent = prefix <> "R"
    saved = prefix <> bytes <> "R"
    source = splice(:insert, 1, byte_size(prefix), "", bytes)

    assert Proof.included(saved, [source], parent, saved) == [{:insert, 1, 0, 128}]
  end

  test "same-line edits and adjacent replacements stay independent" do
    for {saved, sources, transitions} <- [
          {"A-B", [splice(:replace, 1, 0, "a", "A"), splice(:replace, 2, 2, "b", "B")],
           [{"a-b", "a-B", [2]}, {"a-B", "A-B", [1]}, {"a-b", "A-B", [1, 2]}]},
          {"AB", [splice(:replace, 1, 0, "a", "A"), splice(:replace, 2, 1, "b", "B")],
           [{"ab", "aB", [2]}, {"aB", "AB", [1]}, {"ab", "AB", [1, 2]}]}
        ],
        {parent, child, ids} <- transitions do
      assert Proof.included(saved, sources, parent, child) ==
               Enum.map(ids, &{:replace, &1, 0, 1})
    end
  end

  test "a replacement survives adjacent human changes without moving to a different site" do
    source = splice(:replace, 1, 1, "b", "B")
    evidence = [{:replace, 1, 0, 1}]

    assert Proof.included("LBQR", [source], "LbqR", "LBQR") == evidence
    assert Proof.included("LBQR", [source], "LbqR", "LBqR") == evidence
    assert Proof.included("LBqueryR", [source], "LbqR", "LBqueryR") == evidence
    assert Proof.included("LBQR", [source], "LbqR", "LqBR") == []
    assert Proof.included("LBQR", [source], "LbqR", "LBbQR") == []
    assert Proof.included("LBQRbqR", [source], "LbqRbqR", "LbQRBqR") == []
  end

  test "an unchanged replacement is not evidence, but repeated context on one side is safe" do
    assert Proof.included("LBQR", [splice(:replace, 1, 1, "B", "B")], "LBqR", "LBQR") == []

    assert Proof.included("LBqR", [splice(:replace, 1, 1, "b", "B")], "LbqqR", "LBqR") ==
             [{:replace, 1, 0, 1}]
  end

  test "a preserved interior byte disqualifies a replacement on its opposite side" do
    source = splice(:replace, 1, 1, "AB", "CD")
    assert Proof.included("qCDxY\n", [source], "qABxY\n", "xCDzz\n") == []
  end

  test "same bytes at a different site and identical existing neighbors are not evidence" do
    source = splice(:insert, 1, 1, "", "X")
    assert Proof.included("aX|b", [source], "a|b", "a|Xb") == []
    assert Proof.included("aX|b", [source], "za|b", "zXa|b") == []
    assert Proof.included("aX|b", [source], "za|b", "zaX|b") == [{:insert, 1, 0, 1}]

    ambiguous = splice(:insert, 2, 1, "", "x")
    assert Proof.included("LxxR", [ambiguous], "LxR", "LxxR") == []

    alternatives = [splice(:insert, 3, 1, "", "X"), splice(:insert, 4, 2, "", "X")]
    assert Proof.included("aXXb", alternatives, "ab", "aXb") == []
  end

  test "a replacement requires its original preimage to leave from the same site" do
    source = splice(:replace, 1, 1, "x", "Y")
    assert Proof.included("aYb", [source], "axb", "axYb") == []
    assert Proof.included("aYb", [source], "azb", "aYb") == []
    assert Proof.included("aYb", [source], "axb", "aYb") == [{:replace, 1, 0, 1}]
  end

  test "deletion evidence is ordered, partial, and requires the file to remain present" do
    source = splice(:delete, 1, 1, "XY", "")
    assert Proof.included("ab", [source], "aXYb", "aYb") == [{:delete, 1, 0, 1}]
    assert Proof.included("ab", [source], "aYb", "ab") == [{:delete, 1, 1, 2}]
    assert Proof.included("ab", [source], "aZb", "ab") == []

    eof = splice(:delete, 2, 3, "\n", "")
    assert Proof.included("a\nb", [eof], "a\nb\n", "ab\n") == []
    assert Proof.included("a\nb", [eof], "a\nb\n", "a\nb") == [{:delete, 2, 0, 1}]

    whole = splice(:delete, 3, 0, "x", "")
    assert Proof.included("", [whole], "x", nil) == []
    assert Proof.included("", [whole], "x", "") == [{:delete, 3, 0, 1}]
  end

  test "a new tracked file proves the kept insertion without pretending absence is a deletion" do
    assert Proof.included("aXb", [splice(:insert, 1, 1, "", "X")], nil, "aXb") ==
             [{:insert, 1, 0, 1}]

    assert Proof.included("ab", [splice(:delete, 2, 1, "X", "")], nil, "ab") == []
  end

  defp splice(kind, id, point, old, new),
    do: %Source{kind: kind, id: id, offset: 0, point: point, old: old, new: new}
end
