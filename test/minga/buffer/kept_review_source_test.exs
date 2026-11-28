defmodule Minga.Buffer.KeptReviewSourceTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.KeptReview.Source
  alias Minga.Buffer.Provenance

  @task {:minga, "review-task"}

  test "couples each adjacent replacement to its own complete preimage" do
    {step, provenance} = Provenance.open_group(Provenance.new(3), @task, {"review-task", 1})
    edits = [{0, "x", "AA"}, {1, "y", "B"}]

    for mode <- [:each, :batch] do
      edited = Provenance.edit_all(provenance, step, edits, mode)
      sources = Provenance.keep_sources(edited, [step])

      assert [
               %Source{kind: :replace, point: 0, old: "x", new: "AA"},
               %Source{kind: :replace, point: 2, old: "y", new: "B"}
             ] = Source.project(sources, "AABz")
    end
  end

  test "projects complete fragmented replacements with independently owned bytes" do
    prefix = :binary.copy("x", 1024)
    old_first = :binary.copy("α", 40)
    old_second = :binary.copy("β", 45)
    old = old_first <> old_second
    new = :binary.copy("é", 60)
    content = prefix <> new <> prefix
    preimage = prefix <> old <> prefix
    point = byte_size(prefix)
    new_length = byte_size(new)
    gap = point + new_length
    old_length = byte_size(old)
    split = byte_size(old_first)

    written = [
      {:written, {:replace, 1, 1, new_length}, point + 1, new_length - 1},
      {:written, {:replace, 1, 0, new_length}, point, 1}
    ]

    whole = binary_part(preimage, point, old_length)

    for removed <- [
          [{:removed, {:replace, 1, 0, old_length}, gap, whole}],
          [
            {:removed, {:replace, 1, split, old_length}, gap,
             binary_part(preimage, point + split, old_length - split)},
            {:removed, {:replace, 1, 0, old_length}, gap, binary_part(preimage, point, split)}
          ]
        ] do
      assert [%Source{kind: :replace, point: ^point, old: ^old, new: ^new} = source] =
               Source.project(removed ++ written, content)

      assert :binary.referenced_byte_size(source.old) == old_length
      assert :binary.referenced_byte_size(source.new) == byte_size(new)
    end
  end

  test "rejects replacement projections whose extents or adjacency are inexact" do
    written = {:written, {:replace, 1, 0, 3}, 1, 1}
    next_written = {:written, {:replace, 1, 1, 3}, 2, 2}
    removed = {:removed, {:replace, 1, 0, 2}, 4, "x"}
    next_removed = {:removed, {:replace, 1, 1, 2}, 4, "y"}

    for {reason, parts} <- [
          {:written_total, [{:written, {:replace, 1, 1, 4}, 2, 2}, removed, next_removed]},
          {:written_advance, [{:written, {:replace, 1, 1, 3}, 3, 2}, removed, next_removed]},
          {:removed_total, [next_written, removed, {:removed, {:replace, 1, 1, 3}, 4, "y"}]},
          {:removed_offset, [next_written, removed, {:removed, {:replace, 1, 2, 2}, 4, "y"}]},
          {:removed_gap, [next_written, removed, {:removed, {:replace, 1, 1, 2}, 5, "y"}]},
          {:adjacency,
           [next_written, {:removed, {:replace, 1, 0, 2}, 5, "x"},
            {:removed, {:replace, 1, 1, 2}, 5, "y"}]}
        ] do
      assert Source.project([written | parts], "aABCz") == [], inspect(reason)
    end
  end

  test "a later user overwrite cannot turn part of a replacement into proof of the whole" do
    {step, provenance} = Provenance.open_group(Provenance.new(3), @task, {"review-task", 1})
    provenance = Provenance.edit(provenance, step, 1, "x", "ABC")
    {user, provenance} = Provenance.open_group(provenance, :you, nil)
    provenance = Provenance.edit(provenance, user, 2, "B", "b")

    assert [] = Source.project(Provenance.keep_sources(provenance, [step]), "aAbCc")
  end

  test "independent fragments of a pure insertion keep their original source offsets" do
    {step, provenance} = Provenance.open_group(Provenance.new(2), @task, {"review-task", 1})
    provenance = Provenance.edit(provenance, step, 1, "", "XYZ")
    {user, provenance} = Provenance.open_group(provenance, :you, nil)
    provenance = Provenance.edit(provenance, user, 2, "Y", "!")

    assert [
             %Source{kind: :insert, id: id, offset: 0, point: 1, old: "", new: "X"},
             %Source{kind: :insert, id: id, offset: 2, point: 3, old: "", new: "Z"}
           ] = Source.project(Provenance.keep_sources(provenance, [step]), "aX!Zb")
  end

  test "different direct deletions with indistinguishable ordering are not invented as one splice" do
    {first, provenance} = Provenance.open_group(Provenance.new(4), @task, {"review-task", 1})
    provenance = Provenance.edit(provenance, first, 1, "x", "")
    {second, provenance} = Provenance.open_group(provenance, @task, {"review-task", 2})
    provenance = Provenance.edit(provenance, second, 1, "y", "")

    assert [] = Source.project(Provenance.keep_sources(provenance, [first, second]), "ab")
  end

  describe "rebinding a replacement" do
    setup do
      fragments = [
        {:written, {:replace, 1, 0, 6}, 1, 6},
        {:removed, {:replace, 1, 0, 3}, 7, "猫"}
      ]

      [source] = Source.project(fragments, "aé🙂z")
      %{source: source}
    end

    test "moves only the point for a fragmented multibyte replacement", %{source: source} do
      # The first fragment ends inside the four-byte emoji.
      placements = [
        {:visible, {:replace, 1, 3, 6}, 6, 3},
        {:visible, {:replace, 1, 0, 6}, 3, 3}
      ]

      assert Source.rebind(source, "界é🙂z", %{Source.key(source) => placements}) ==
               [%{source | point: 3}]
    end

    test "rejects placements that do not prove the full postimage", %{source: source} do
      first = {:visible, {:replace, 1, 0, 6}, 3, 3}
      second = {:visible, {:replace, 1, 3, 6}, 6, 3}
      content = "界é🙂z"

      for {reason, saved, placements} <- [
            {:missing, content, [first]},
            {:duplicate, content, [first, second, first]},
            {:mismatched_bytes, "界é🙃z", [first, second]},
            {:inconsistent_total, content, [first, {:visible, {:replace, 1, 3, 7}, 6, 3}]},
            {:complete_shorter_total, content, [{:visible, {:replace, 1, 0, 3}, 3, 3}]}
          ] do
        bindings = %{Source.key(source) => placements}
        assert Source.rebind(source, saved, bindings) == [], inspect(reason)
      end
    end
  end
end
