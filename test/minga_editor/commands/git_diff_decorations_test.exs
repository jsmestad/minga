defmodule MingaEditor.Commands.GitDiffDecorationsTest do
  @moduledoc "Tests for diff view decoration application and sign generation."
  use ExUnit.Case, async: true

  alias Minga.Core.Decorations
  alias Minga.Core.DiffView

  describe "diff sign generation" do
    test "produces :added signs for added lines" do
      metadata = [
        %{type: :context, original_line: 0, fold_count: nil},
        %{type: :added, original_line: 1, fold_count: nil},
        %{type: :added, original_line: 2, fold_count: nil},
        %{type: :context, original_line: 3, fold_count: nil}
      ]

      signs = diff_signs_from_metadata(metadata)

      assert signs[1] == :added
      assert signs[2] == :added
      refute Map.has_key?(signs, 0)
      refute Map.has_key?(signs, 3)
    end

    test "produces :removed signs for removed lines" do
      metadata = [
        %{type: :context, original_line: 0, fold_count: nil},
        %{type: :removed, original_line: nil, fold_count: nil},
        %{type: :context, original_line: 1, fold_count: nil}
      ]

      signs = diff_signs_from_metadata(metadata)

      assert signs[1] == :removed
      refute Map.has_key?(signs, 0)
      refute Map.has_key?(signs, 2)
    end

    test "handles mixed added and removed lines" do
      metadata = [
        %{type: :removed, original_line: nil, fold_count: nil},
        %{type: :added, original_line: 0, fold_count: nil},
        %{type: :fold, original_line: nil, fold_count: 5}
      ]

      signs = diff_signs_from_metadata(metadata)

      assert signs[0] == :removed
      assert signs[1] == :added
      refute Map.has_key?(signs, 2)
    end

    test "returns empty map for all context lines" do
      metadata = [
        %{type: :context, original_line: 0, fold_count: nil},
        %{type: :context, original_line: 1, fold_count: nil}
      ]

      signs = diff_signs_from_metadata(metadata)
      assert signs == %{}
    end
  end

  describe "diff view integration" do
    test "DiffView.build produces metadata suitable for decoration" do
      result = DiffView.build("old line\n", "new line\n")

      assert is_list(result.line_metadata)
      assert result.line_metadata != []

      types = Enum.map(result.line_metadata, & &1.type)
      assert :removed in types or :added in types
    end

    test "decoration application creates highlights for added/removed lines" do
      metadata = [
        %{type: :context, original_line: 0, fold_count: nil},
        %{type: :removed, original_line: nil, fold_count: nil},
        %{type: :added, original_line: 1, fold_count: nil},
        %{type: :fold, original_line: nil, fold_count: 3}
      ]

      decs =
        metadata
        |> Enum.with_index()
        |> Enum.reduce(Decorations.new(), fn {meta, idx}, decs ->
          case meta.type do
            :added ->
              {_id, decs} =
                Decorations.add_highlight(decs, {idx, 0}, {idx, 9999},
                  style: Minga.Core.Face.new(bg: 0x224422),
                  group: :diff
                )

              decs

            :removed ->
              {_id, decs} =
                Decorations.add_highlight(decs, {idx, 0}, {idx, 9999},
                  style: Minga.Core.Face.new(bg: 0x442222),
                  group: :diff
                )

              decs

            _ ->
              decs
          end
        end)

      highlights = Decorations.highlights_for_lines(decs, 0, 3)
      assert length(highlights) == 2
    end
  end

  # Mirrors the private function in ContentHelpers for testability
  defp diff_signs_from_metadata(line_metadata) do
    line_metadata
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn
      {%{type: :added}, idx}, acc -> Map.put(acc, idx, :added)
      {%{type: :removed}, idx}, acc -> Map.put(acc, idx, :removed)
      _, acc -> acc
    end)
  end
end
