defmodule Minga.Core.ByteAlignmentTest do
  use ExUnit.Case, async: true

  alias Minga.Core.ByteAlignment

  test "repeated bytes do not identify which byte was removed" do
    source = "LxxR"
    offsets = MapSet.new(0..3)

    assert ByteAlignment.classify(source, "LxR", offsets, 1) ==
             {:ok,
              %{
                0 => {:matched, 0},
                1 => {:ambiguous, 1, 1},
                2 => {:ambiguous, 1, 1},
                3 => {:matched, 2}
              }}
  end

  test "forced correspondence shifts across unrelated edits and uses byte offsets" do
    offsets = MapSet.new([1, 2, 3])

    assert ByteAlignment.classify("a\0Xb", "za\0Yb", offsets, 3) ==
             {:ok, %{1 => {:matched, 2}, 2 => :unmatched, 3 => {:matched, 4}}}

    assert ByteAlignment.classify("a\0Xb", "za\0Yb", offsets, 2) == :over_budget
  end

  test "the exact bound retains all ties, matching every optimal path of tiny byte strings" do
    for source <- words(3), destination <- words(3) do
      offsets = MapSet.new(0..(byte_size(source) - 1)//1)
      paths = alignments(:binary.bin_to_list(source), :binary.bin_to_list(destination), 0)
      distance = paths |> Enum.map(&elem(&1, 0)) |> Enum.min()
      shortest = for {^distance, path} <- paths, do: path

      expected =
        Map.new(offsets, fn offset ->
          case Enum.uniq(Enum.map(shortest, &Enum.at(&1, offset))) do
            [only] ->
              {offset, only}

            choices ->
              {first, last} =
                choices
                |> Enum.flat_map(fn
                  {:matched, position} -> [position]
                  :unmatched -> []
                end)
                |> Enum.min_max()

              {offset, {:ambiguous, first, last}}
          end
        end)

      assert {:ok, ^expected} = ByteAlignment.classify(source, destination, offsets, distance)

      if distance == abs(byte_size(source) - byte_size(destination)) do
        assert {:ok, ^expected} = ByteAlignment.classify_subsequence(source, destination, offsets)
      else
        assert :not_subsequence = ByteAlignment.classify_subsequence(source, destination, offsets)
      end
    end
  end

  defp words(0), do: [""]

  defp words(depth),
    do: ["" | for(word <- words(depth - 1), byte <- [0, 1], do: <<byte, word::binary>>)]

  defp alignments([], destination, _offset), do: [{length(destination), []}]

  defp alignments([byte | source], destination, offset) do
    drop =
      for {count, route} <- alignments(source, destination, offset),
          do: {count + 1, [:unmatched | route]}

    case destination do
      [] ->
        drop

      [other | rest] ->
        insert =
          for {count, route} <- alignments([byte | source], rest, offset + 1),
              do: {count + 1, route}

        matching_alignments(byte, other, source, rest, offset) ++ drop ++ insert
    end
  end

  defp matching_alignments(byte, byte, source, destination, offset) do
    for {count, route} <- alignments(source, destination, offset + 1),
        do: {count, [{:matched, offset} | route]}
  end

  defp matching_alignments(_byte, _other, _source, _destination, _offset), do: []
end
