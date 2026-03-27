defmodule Minga.Core.DiffView do
  @moduledoc """
  Pure calculation module for building unified diff views.

  Takes base (HEAD) lines and current lines with hunks, produces interleaved
  text with line metadata for rendering as a read-only buffer with decorations.
  """

  alias Minga.Core.Diff

  @typedoc "Metadata for a single display line in the diff view."
  @type line_meta :: %{
          type: :context | :added | :removed | :header | :fold,
          original_line: non_neg_integer() | nil,
          fold_count: non_neg_integer() | nil
        }

  @typedoc "Result of building a diff view: the text content and per-line metadata."
  @type diff_view_result :: %{
          text: String.t(),
          line_metadata: [line_meta()],
          hunk_lines: [non_neg_integer()]
        }

  @context_lines 3
  @fold_threshold 6

  @doc """
  Builds a unified diff view from base and current content.

  Returns a map with:
  - `:text` - the interleaved unified diff text to inject into a Buffer
  - `:line_metadata` - per-line metadata for decorations (type, original line number)
  - `:hunk_lines` - display line indices where hunks start (for ]c/[c navigation)
  """
  @spec build(String.t(), String.t()) :: diff_view_result()
  def build(base_content, current_content) do
    base_lines = split_lines(base_content)
    current_lines = split_lines(current_content)
    hunks = Diff.diff_lines(base_lines, current_lines)

    build_from_hunks(base_lines, current_lines, hunks)
  end

  @doc """
  Builds a unified diff view from pre-computed hunks.
  """
  @spec build_from_hunks([String.t()], [String.t()], [Diff.hunk()]) :: diff_view_result()
  def build_from_hunks(_base_lines, _current_lines, []) do
    %{
      text: "No changes",
      line_metadata: [%{type: :context, original_line: nil, fold_count: nil}],
      hunk_lines: []
    }
  end

  def build_from_hunks(base_lines, current_lines, hunks) do
    # Build regions: alternating context and hunk sections
    regions = build_regions(base_lines, current_lines, hunks)

    {display_lines, metadata, hunk_indices} =
      Enum.reduce(regions, {[], [], []}, fn region, {lines_acc, meta_acc, hunk_acc} ->
        display_line_idx = length(lines_acc)

        case region do
          {:context, ctx_lines, start_orig} ->
            add_context_with_folding(lines_acc, meta_acc, hunk_acc, ctx_lines, start_orig)

          {:hunk, hunk_lines_list} ->
            add_hunk_lines(lines_acc, meta_acc, hunk_acc, hunk_lines_list, display_line_idx)
        end
      end)

    text = Enum.join(display_lines, "\n")

    %{
      text: text,
      line_metadata: metadata,
      hunk_lines: Enum.reverse(hunk_indices)
    }
  end

  # ── Private ────────────────────────────────────────────────────────────

  @spec add_hunk_lines(
          [String.t()],
          [line_meta()],
          [non_neg_integer()],
          list(),
          non_neg_integer()
        ) ::
          {[String.t()], [line_meta()], [non_neg_integer()]}
  defp add_hunk_lines(lines_acc, meta_acc, hunk_acc, hunk_lines_list, display_line_idx) do
    hunk_acc = [display_line_idx + length(hunk_lines_list) - 1 | hunk_acc]

    {new_lines, new_meta} =
      Enum.reduce(hunk_lines_list, {lines_acc, meta_acc}, fn {text, type, orig_line}, {la, ma} ->
        meta = %{type: type, original_line: orig_line, fold_count: nil}
        {la ++ [text], ma ++ [meta]}
      end)

    {new_lines, new_meta, hunk_acc}
  end

  @spec build_regions([String.t()], [String.t()], [Diff.hunk()]) :: [term()]
  defp build_regions(base_lines, current_lines, hunks) do
    # Sort hunks by start_line
    sorted_hunks = Enum.sort_by(hunks, & &1.start_line)

    {regions, last_end} =
      Enum.reduce(sorted_hunks, {[], 0}, fn hunk, {regions_acc, prev_end} ->
        # Context before this hunk
        ctx_start = prev_end
        ctx_end = hunk.start_line

        regions_acc =
          if ctx_end > ctx_start do
            ctx = Enum.slice(current_lines, ctx_start..(ctx_end - 1))
            regions_acc ++ [{:context, ctx, ctx_start}]
          else
            regions_acc
          end

        # The hunk itself
        hunk_display = build_hunk_display(hunk, base_lines, current_lines)

        # Calculate where the hunk ends in current lines
        hunk_end =
          case hunk.type do
            :deleted -> hunk.start_line
            _ -> hunk.start_line + hunk.count
          end

        {regions_acc ++ [{:hunk, hunk_display}], hunk_end}
      end)

    # Trailing context after last hunk
    if last_end < length(current_lines) do
      ctx = Enum.slice(current_lines, last_end..(length(current_lines) - 1))
      regions ++ [{:context, ctx, last_end}]
    else
      regions
    end
  end

  @spec build_hunk_display(Diff.hunk(), [String.t()], [String.t()]) :: [
          {String.t(), :added | :removed | :context, non_neg_integer() | nil}
        ]
  defp build_hunk_display(%{type: :added} = hunk, _base_lines, current_lines) do
    current_lines
    |> Enum.slice(hunk.start_line..(hunk.start_line + hunk.count - 1))
    |> Enum.with_index(hunk.start_line)
    |> Enum.map(fn {line, idx} -> {line, :added, idx} end)
  end

  defp build_hunk_display(%{type: :deleted} = hunk, _base_lines, _current_lines) do
    hunk.old_lines
    |> Enum.map(fn line -> {line, :removed, nil} end)
  end

  defp build_hunk_display(%{type: :modified} = hunk, _base_lines, current_lines) do
    # Show old lines as removed, then new lines as added
    removed =
      hunk.old_lines
      |> Enum.map(fn line -> {line, :removed, nil} end)

    added =
      current_lines
      |> Enum.slice(hunk.start_line..(hunk.start_line + hunk.count - 1))
      |> Enum.with_index(hunk.start_line)
      |> Enum.map(fn {line, idx} -> {line, :added, idx} end)

    removed ++ added
  end

  @spec add_context_with_folding(
          [String.t()],
          [line_meta()],
          [non_neg_integer()],
          [String.t()],
          non_neg_integer()
        ) ::
          {[String.t()], [line_meta()], [non_neg_integer()]}
  defp add_context_with_folding(lines, meta, hunks, ctx_lines, start_orig) do
    count = length(ctx_lines)

    if count > @fold_threshold do
      # Show first @context_lines, fold, show last @context_lines
      head = Enum.take(ctx_lines, @context_lines)
      tail = Enum.take(ctx_lines, -@context_lines)
      fold_count = count - @context_lines * 2

      head_meta =
        Enum.with_index(head, start_orig)
        |> Enum.map(fn {_line, idx} ->
          %{type: :context, original_line: idx, fold_count: nil}
        end)

      fold_meta = [%{type: :fold, original_line: nil, fold_count: fold_count}]

      tail_start = start_orig + count - @context_lines

      tail_meta =
        Enum.with_index(tail, tail_start)
        |> Enum.map(fn {_line, idx} ->
          %{type: :context, original_line: idx, fold_count: nil}
        end)

      fold_text = "  #{fold_count} unchanged lines"

      {lines ++ head ++ [fold_text] ++ tail, meta ++ head_meta ++ fold_meta ++ tail_meta, hunks}
    else
      ctx_meta =
        Enum.with_index(ctx_lines, start_orig)
        |> Enum.map(fn {_line, idx} ->
          %{type: :context, original_line: idx, fold_count: nil}
        end)

      {lines ++ ctx_lines, meta ++ ctx_meta, hunks}
    end
  end

  @spec split_lines(String.t()) :: [String.t()]
  defp split_lines(""), do: []
  defp split_lines(content), do: String.split(content, "\n")
end
