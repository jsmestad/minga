defmodule Minga.Core.DiffView do
  @moduledoc """
  Pure calculation module for building unified diff views.

  Takes base (HEAD) lines and current lines with hunks, produces interleaved
  text with line metadata for rendering as a read-only buffer with decorations.
  """

  alias Minga.Core.Diff

  @type line_type :: :context | :added | :removed | :header | :fold
  @type pane_line_type :: :context | :added | :removed | :blank | :fold

  @typedoc "Metadata for a single display line in the diff view."
  @type line_meta :: %{
          required(:type) => line_type(),
          required(:original_line) => non_neg_integer() | nil,
          required(:fold_count) => non_neg_integer() | nil,
          required(:word_changes) => [Diff.char_range()] | nil,
          optional(:left_type) => pane_line_type(),
          optional(:right_type) => pane_line_type(),
          optional(:left_width) => pos_integer(),
          optional(:separator_col) => non_neg_integer(),
          optional(:left_word_changes) => [Diff.char_range()] | nil,
          optional(:right_word_changes) => [Diff.char_range()] | nil
        }

  @typedoc "Result of building a diff view: the text content and per-line metadata."
  @type diff_view_result :: %{
          text: String.t(),
          line_metadata: [line_meta()],
          hunk_lines: [non_neg_integer()]
        }

  @typep display_acc :: %{
           reversed_text: [String.t()],
           reversed_metadata: [line_meta()],
           next_row: non_neg_integer(),
           reversed_hunk_ends: [integer()]
         }

  @typep unified_hunk_row ::
           {String.t(), :added | :removed | :context, non_neg_integer() | nil,
            [Diff.char_range()] | nil}

  @typep modified_line_pair ::
           {:paired, String.t(), String.t(), non_neg_integer(), non_neg_integer()}
           | {:unpaired_old, String.t()}
           | {:unpaired_new, String.t(), non_neg_integer()}

  @typep indexed_line :: {String.t(), non_neg_integer()}
  @typep side_by_side_line :: %{
           left: String.t(),
           right: String.t(),
           left_type: pane_line_type(),
           right_type: pane_line_type(),
           original_line: non_neg_integer() | nil,
           fold_count: non_neg_integer() | nil,
           left_word_changes: [Diff.char_range()] | nil,
           right_word_changes: [Diff.char_range()] | nil
         }

  @empty_display %{reversed_text: [], reversed_metadata: [], next_row: 0, reversed_hunk_ends: []}

  @context_lines 3
  @fold_threshold 6
  @line_pair_similarity_threshold 0.35
  @max_line_pair_similarity_attempts 400
  @default_side_by_side_pane_width 80
  @doc """
  Builds a unified diff view from base and current content.

  Returns a map with:
  - `:text` - the interleaved unified diff text to inject into a Buffer
  - `:line_metadata` - per-line metadata for decorations (type, original line number)
  - `:hunk_lines` - display line indices where hunks end (for hunk position and actions)
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
      line_metadata: [%{type: :context, original_line: nil, fold_count: nil, word_changes: nil}],
      hunk_lines: []
    }
  end

  def build_from_hunks(base_lines, current_lines, hunks) do
    # Build regions: alternating context and hunk sections
    regions = build_regions(base_lines, current_lines, hunks)

    regions
    |> Enum.reduce(@empty_display, fn
      {:context, ctx_lines, start_orig}, acc ->
        add_context_with_folding(acc, ctx_lines, start_orig)

      {:hunk, hunk_rows}, acc ->
        add_hunk_lines(acc, hunk_rows)
    end)
    |> finish_display()
  end

  @doc """
  Builds a GUI side-by-side diff view from base and current content.

  The result uses one rendered buffer line per aligned row. The left pane carries the old version, the right pane carries the new version, and blank filler rows preserve vertical alignment across additions and deletions. Metadata includes pane-local change ranges so GUI decorations can highlight each pane independently.
  """
  @spec build_side_by_side(String.t(), String.t(), pos_integer()) :: diff_view_result()
  def build_side_by_side(
        base_content,
        current_content,
        pane_width \\ @default_side_by_side_pane_width
      ) do
    base_lines = split_lines(base_content)
    current_lines = split_lines(current_content)
    hunks = Diff.diff_lines(base_lines, current_lines)

    build_side_by_side_from_hunks(base_lines, current_lines, hunks, pane_width)
  end

  @doc """
  Builds a GUI side-by-side diff view from pre-computed hunks.
  """
  @spec build_side_by_side_from_hunks([String.t()], [String.t()], [Diff.hunk()], pos_integer()) ::
          diff_view_result()
  def build_side_by_side_from_hunks(_base_lines, _current_lines, [], pane_width) do
    {line, meta} = format_side_by_side_line(no_changes_side_by_side_line(), pane_width)

    %{
      text: line,
      line_metadata: [meta],
      hunk_lines: []
    }
  end

  def build_side_by_side_from_hunks(base_lines, current_lines, hunks, pane_width) do
    regions = build_side_by_side_regions(base_lines, current_lines, hunks)

    regions
    |> Enum.reduce(@empty_display, fn
      {:context, ctx_lines, start_orig}, acc ->
        add_context_side_by_side(acc, ctx_lines, start_orig, pane_width)

      {:hunk, hunk}, acc ->
        add_hunk_side_by_side(acc, hunk, current_lines, pane_width)
    end)
    |> finish_display()
  end

  # ── Private ────────────────────────────────────────────────────────────

  @spec append_row(display_acc(), String.t(), line_meta()) :: display_acc()
  defp append_row(acc, text, meta) do
    %{
      acc
      | reversed_text: [text | acc.reversed_text],
        reversed_metadata: [meta | acc.reversed_metadata],
        next_row: acc.next_row + 1
    }
  end

  @spec record_hunk_end(display_acc()) :: display_acc()
  defp record_hunk_end(acc) do
    # Even an empty hunk ends at the previous display row.
    %{acc | reversed_hunk_ends: [acc.next_row - 1 | acc.reversed_hunk_ends]}
  end

  @spec finish_display(display_acc()) :: diff_view_result()
  defp finish_display(acc) do
    %{
      text: acc.reversed_text |> Enum.reverse() |> Enum.join("\n"),
      line_metadata: Enum.reverse(acc.reversed_metadata),
      hunk_lines: Enum.reverse(acc.reversed_hunk_ends)
    }
  end

  @spec add_hunk_side_by_side(display_acc(), Diff.hunk(), [String.t()], pos_integer()) ::
          display_acc()
  defp add_hunk_side_by_side(acc, hunk, current_lines, pane_width) do
    hunk
    |> build_hunk_side_by_side(current_lines)
    |> Enum.reduce(acc, &append_side_by_side_row(&2, &1, pane_width))
    |> record_hunk_end()
  end

  @spec add_context_side_by_side(display_acc(), [String.t()], non_neg_integer(), pos_integer()) ::
          display_acc()
  defp add_context_side_by_side(acc, ctx_lines, start_orig, pane_width) do
    count = length(ctx_lines)

    if count > @fold_threshold do
      tail_offset = count - @context_lines
      fold_count = tail_offset - @context_lines

      acc
      |> add_context_rows_side_by_side(
        Enum.take(ctx_lines, @context_lines),
        start_orig,
        pane_width
      )
      |> append_side_by_side_row(fold_side_by_side_line(fold_count), pane_width)
      |> add_context_rows_side_by_side(
        Enum.drop(ctx_lines, tail_offset),
        start_orig + tail_offset,
        pane_width
      )
    else
      add_context_rows_side_by_side(acc, ctx_lines, start_orig, pane_width)
    end
  end

  @spec add_context_rows_side_by_side(
          display_acc(),
          [String.t()],
          non_neg_integer(),
          pos_integer()
        ) ::
          display_acc()
  defp add_context_rows_side_by_side(acc, [], _original_line, _pane_width), do: acc

  defp add_context_rows_side_by_side(acc, [line | rest], original_line, pane_width) do
    row = %{
      left: line,
      right: line,
      left_type: :context,
      right_type: :context,
      original_line: original_line,
      fold_count: nil,
      left_word_changes: nil,
      right_word_changes: nil
    }

    acc
    |> append_side_by_side_row(row, pane_width)
    |> add_context_rows_side_by_side(rest, original_line + 1, pane_width)
  end

  @spec fold_side_by_side_line(non_neg_integer()) :: side_by_side_line()
  defp fold_side_by_side_line(fold_count) do
    text = "  #{fold_count} unchanged lines"

    %{
      left: text,
      right: "",
      left_type: :fold,
      right_type: :blank,
      original_line: nil,
      fold_count: fold_count,
      left_word_changes: nil,
      right_word_changes: nil
    }
  end

  @spec no_changes_side_by_side_line() :: side_by_side_line()
  defp no_changes_side_by_side_line do
    %{
      left: "No changes",
      right: "No changes",
      left_type: :context,
      right_type: :context,
      original_line: nil,
      fold_count: nil,
      left_word_changes: nil,
      right_word_changes: nil
    }
  end

  @spec build_hunk_side_by_side(Diff.hunk(), [String.t()]) :: [side_by_side_line()]
  defp build_hunk_side_by_side(%{type: :added} = hunk, current_lines) do
    current_lines
    |> Enum.slice(hunk.start_line..(hunk.start_line + hunk.count - 1))
    |> Enum.with_index(hunk.start_line)
    |> Enum.map(fn {line, idx} ->
      %{
        left: "",
        right: line,
        left_type: :blank,
        right_type: :added,
        original_line: idx,
        fold_count: nil,
        left_word_changes: nil,
        right_word_changes: nil
      }
    end)
  end

  defp build_hunk_side_by_side(%{type: :deleted} = hunk, _current_lines) do
    Enum.map(hunk.old_lines, fn line ->
      %{
        left: line,
        right: "",
        left_type: :removed,
        right_type: :blank,
        original_line: nil,
        fold_count: nil,
        left_word_changes: nil,
        right_word_changes: nil
      }
    end)
  end

  defp build_hunk_side_by_side(%{type: :modified} = hunk, current_lines) do
    new_lines = Enum.slice(current_lines, hunk.start_line..(hunk.start_line + hunk.count - 1))

    hunk.old_lines
    |> pair_modified_lines(new_lines)
    |> Enum.map(&modified_pair_side_by_side_line(&1, hunk.start_line))
  end

  @spec modified_pair_side_by_side_line(modified_line_pair(), non_neg_integer()) ::
          side_by_side_line()
  defp modified_pair_side_by_side_line(
         {:paired, old_line, new_line, _old_idx, new_idx},
         start_line
       ) do
    {del_ranges, ins_ranges} = Diff.word_diff_ranges(old_line, new_line)

    %{
      left: old_line,
      right: new_line,
      left_type: :removed,
      right_type: :added,
      original_line: start_line + new_idx,
      fold_count: nil,
      left_word_changes: del_ranges,
      right_word_changes: ins_ranges
    }
  end

  defp modified_pair_side_by_side_line({:unpaired_old, old_line}, _start_line) do
    %{
      left: old_line,
      right: "",
      left_type: :removed,
      right_type: :blank,
      original_line: nil,
      fold_count: nil,
      left_word_changes: nil,
      right_word_changes: nil
    }
  end

  defp modified_pair_side_by_side_line({:unpaired_new, new_line, new_idx}, start_line) do
    %{
      left: "",
      right: new_line,
      left_type: :blank,
      right_type: :added,
      original_line: start_line + new_idx,
      fold_count: nil,
      left_word_changes: nil,
      right_word_changes: nil
    }
  end

  @spec append_side_by_side_row(display_acc(), side_by_side_line(), pos_integer()) ::
          display_acc()
  defp append_side_by_side_row(acc, row, pane_width) do
    {text, meta} = format_side_by_side_line(row, pane_width)
    append_row(acc, text, meta)
  end

  @spec format_side_by_side_line(side_by_side_line(), pos_integer()) :: {String.t(), line_meta()}
  defp format_side_by_side_line(line, pane_width) do
    left = truncate_for_pane(line.left, pane_width)
    right = truncate_for_pane(line.right, pane_width)
    separator = " │ "
    text = String.pad_trailing(left, pane_width) <> separator <> right
    separator_col = pane_width + 1

    meta = %{
      type: combined_side_by_side_type(line.left_type, line.right_type),
      original_line: line.original_line,
      fold_count: line.fold_count,
      word_changes: nil,
      left_type: line.left_type,
      right_type: line.right_type,
      left_width: pane_width,
      separator_col: separator_col,
      left_word_changes: clamp_word_changes(line.left_word_changes, pane_width),
      right_word_changes: clamp_word_changes(line.right_word_changes, pane_width)
    }

    {text, meta}
  end

  @spec truncate_for_pane(String.t(), pos_integer()) :: String.t()
  defp truncate_for_pane(text, pane_width) do
    if String.length(text) > pane_width do
      String.slice(text, 0, pane_width)
    else
      text
    end
  end

  @spec clamp_word_changes([Diff.char_range()] | nil, pos_integer()) :: [Diff.char_range()] | nil
  defp clamp_word_changes(nil, _pane_width), do: nil

  defp clamp_word_changes(word_changes, pane_width) do
    word_changes
    |> Enum.map(&clamp_word_change(&1, pane_width))
    |> Enum.reject(&is_nil/1)
  end

  @spec clamp_word_change(Diff.char_range(), pos_integer()) :: Diff.char_range() | nil
  defp clamp_word_change({start_col, _end_col}, pane_width) when start_col >= pane_width, do: nil

  defp clamp_word_change({start_col, end_col}, pane_width) do
    {start_col, min(end_col, pane_width)}
  end

  @spec combined_side_by_side_type(pane_line_type(), pane_line_type()) :: line_type()
  defp combined_side_by_side_type(:fold, _right_type), do: :fold
  defp combined_side_by_side_type(_left_type, :fold), do: :fold
  defp combined_side_by_side_type(:removed, _right_type), do: :removed
  defp combined_side_by_side_type(_left_type, :added), do: :added
  defp combined_side_by_side_type(_left_type, _right_type), do: :context

  @spec add_hunk_lines(display_acc(), [unified_hunk_row()]) :: display_acc()
  defp add_hunk_lines(acc, hunk_rows) do
    hunk_rows
    |> Enum.reduce(acc, fn {text, type, orig_line, word_changes}, acc ->
      meta = %{
        type: type,
        original_line: orig_line,
        fold_count: nil,
        word_changes: word_changes
      }

      append_row(acc, text, meta)
    end)
    |> record_hunk_end()
  end

  @spec build_regions([String.t()], [String.t()], [Diff.hunk()]) :: [term()]
  defp build_regions(base_lines, current_lines, hunks) do
    build_regions(base_lines, current_lines, hunks, &build_hunk_display/3)
  end

  @spec build_side_by_side_regions([String.t()], [String.t()], [Diff.hunk()]) :: [term()]
  defp build_side_by_side_regions(base_lines, current_lines, hunks) do
    build_regions(base_lines, current_lines, hunks, fn hunk, _base_lines, _current_lines ->
      hunk
    end)
  end

  @spec build_regions([String.t()], [String.t()], [Diff.hunk()], (Diff.hunk(),
                                                                  [String.t()],
                                                                  [String.t()] ->
                                                                    term())) :: [term()]
  defp build_regions(base_lines, current_lines, hunks, build_hunk) do
    sorted_hunks = Enum.sort_by(hunks, & &1.start_line)

    {regions_reversed, last_end} =
      Enum.reduce(sorted_hunks, {[], 0}, fn hunk, {regions_acc, prev_end} ->
        ctx_start = prev_end
        ctx_end = hunk.start_line

        regions_acc =
          if ctx_end > ctx_start do
            ctx = Enum.slice(current_lines, ctx_start..(ctx_end - 1))
            [{:context, ctx, ctx_start} | regions_acc]
          else
            regions_acc
          end

        hunk_display = build_hunk.(hunk, base_lines, current_lines)

        hunk_end =
          case hunk.type do
            :deleted -> hunk.start_line
            _ -> hunk.start_line + hunk.count
          end

        {[{:hunk, hunk_display} | regions_acc], hunk_end}
      end)

    regions = Enum.reverse(regions_reversed)

    if last_end < Enum.count(current_lines) do
      ctx = Enum.slice(current_lines, last_end..(Enum.count(current_lines) - 1))
      Enum.concat(regions, [{:context, ctx, last_end}])
    else
      regions
    end
  end

  @spec build_hunk_display(Diff.hunk(), [String.t()], [String.t()]) :: [unified_hunk_row()]
  defp build_hunk_display(%{type: :added} = hunk, _base_lines, current_lines) do
    current_lines
    |> Enum.slice(hunk.start_line..(hunk.start_line + hunk.count - 1))
    |> Enum.with_index(hunk.start_line)
    |> Enum.map(fn {line, idx} -> {line, :added, idx, nil} end)
  end

  defp build_hunk_display(%{type: :deleted} = hunk, _base_lines, _current_lines) do
    hunk.old_lines
    |> Enum.map(fn line -> {line, :removed, nil, nil} end)
  end

  defp build_hunk_display(%{type: :modified} = hunk, _base_lines, current_lines) do
    new_lines =
      Enum.slice(current_lines, hunk.start_line..(hunk.start_line + hunk.count - 1))

    paired = pair_modified_lines(hunk.old_lines, new_lines)

    {removed_entries, added_entries} =
      Enum.reduce(paired, {[], []}, fn
        {:paired, old_line, new_line, _old_idx, new_idx}, {rem_acc, add_acc} ->
          {del_ranges, ins_ranges} = Diff.word_diff_ranges(old_line, new_line)
          rem_entry = {old_line, :removed, nil, del_ranges}
          add_entry = {new_line, :added, hunk.start_line + new_idx, ins_ranges}
          {[rem_entry | rem_acc], [add_entry | add_acc]}

        {:unpaired_old, old_line}, {rem_acc, add_acc} ->
          {[{old_line, :removed, nil, nil} | rem_acc], add_acc}

        {:unpaired_new, new_line, new_idx}, {rem_acc, add_acc} ->
          {rem_acc, [{new_line, :added, hunk.start_line + new_idx, nil} | add_acc]}
      end)

    Enum.reverse(removed_entries) ++ Enum.reverse(added_entries)
  end

  @spec pair_modified_lines([String.t()], [String.t()]) :: [modified_line_pair()]
  defp pair_modified_lines(old_lines, new_lines) do
    pair_modified_lines(old_lines, new_lines, Enum.count(old_lines), Enum.count(new_lines))
  end

  @spec pair_modified_lines([String.t()], [String.t()], non_neg_integer(), non_neg_integer()) :: [
          modified_line_pair()
        ]
  defp pair_modified_lines(old_lines, new_lines, count, count) do
    old_lines
    |> Enum.with_index()
    |> Enum.zip(Enum.with_index(new_lines))
    |> Enum.map(fn {{old, old_idx}, {new, new_idx}} ->
      {:paired, old, new, old_idx, new_idx}
    end)
  end

  defp pair_modified_lines(old_lines, new_lines, old_count, new_count)
       when old_count * new_count > @max_line_pair_similarity_attempts do
    unpaired_old = Enum.map(old_lines, fn line -> {:unpaired_old, line} end)

    unpaired_new =
      new_lines
      |> Enum.with_index()
      |> Enum.map(fn {line, idx} -> {:unpaired_new, line, idx} end)

    unpaired_old ++ unpaired_new
  end

  defp pair_modified_lines(old_lines, new_lines, _old_count, _new_count) do
    pair_lines_by_similarity(Enum.with_index(old_lines), Enum.with_index(new_lines), [])
  end

  @spec pair_lines_by_similarity([indexed_line()], [indexed_line()], [modified_line_pair()]) :: [
          modified_line_pair()
        ]
  defp pair_lines_by_similarity([], new_indexed, acc) do
    unpaired_new = Enum.map(new_indexed, fn {line, idx} -> {:unpaired_new, line, idx} end)
    Enum.reverse(acc) ++ unpaired_new
  end

  defp pair_lines_by_similarity(old_indexed, [], acc) do
    unpaired_old = Enum.map(old_indexed, fn {line, _idx} -> {:unpaired_old, line} end)
    Enum.reverse(acc) ++ unpaired_old
  end

  defp pair_lines_by_similarity([{old, old_idx} | old_rest], [{new, new_idx} | new_rest], acc) do
    if similar_line?(old, new) do
      pair_lines_by_similarity(old_rest, new_rest, [{:paired, old, new, old_idx, new_idx} | acc])
    else
      pair_unmatched_line(old, old_idx, old_rest, [{new, new_idx} | new_rest], acc)
    end
  end

  @spec pair_unmatched_line(String.t(), non_neg_integer(), [indexed_line()], [indexed_line()], [
          modified_line_pair()
        ]) :: [modified_line_pair()]
  defp pair_unmatched_line(old, old_idx, old_rest, new_indexed, acc) do
    case split_at_similar_line(old, new_indexed, []) do
      nil ->
        pair_lines_by_similarity(old_rest, new_indexed, [{:unpaired_old, old} | acc])

      {prefix, {new, new_idx}, suffix} ->
        acc =
          Enum.reduce(prefix, acc, fn {line, idx}, inner ->
            [{:unpaired_new, line, idx} | inner]
          end)

        pair_lines_by_similarity(old_rest, suffix, [{:paired, old, new, old_idx, new_idx} | acc])
    end
  end

  @spec split_at_similar_line(String.t(), [indexed_line()], [indexed_line()]) ::
          {[indexed_line()], indexed_line(), [indexed_line()]} | nil
  defp split_at_similar_line(_line, [], _prefix), do: nil

  defp split_at_similar_line(line, [{candidate, _idx} = entry | rest], prefix) do
    if similar_line?(line, candidate) do
      {Enum.reverse(prefix), entry, rest}
    else
      split_at_similar_line(line, rest, [entry | prefix])
    end
  end

  @spec similar_line?(String.t(), String.t()) :: boolean()
  defp similar_line?(line, line), do: true
  defp similar_line?("", _new_line), do: false
  defp similar_line?(_old_line, ""), do: false

  defp similar_line?(old_line, new_line)
       when byte_size(old_line) > 500 or byte_size(new_line) > 500, do: false

  defp similar_line?(old_line, new_line) do
    line_similarity(old_line, new_line) >= @line_pair_similarity_threshold
  end

  @spec line_similarity(String.t(), String.t()) :: float()
  defp line_similarity(old_line, new_line) do
    old_len = String.length(old_line)
    new_len = String.length(new_line)

    equal_len =
      old_line
      |> String.myers_difference(new_line)
      |> Enum.reduce(0, fn
        {:eq, text}, acc -> acc + String.length(text)
        {_tag, _text}, acc -> acc
      end)

    2.0 * equal_len / (old_len + new_len)
  end

  @spec add_context_with_folding(display_acc(), [String.t()], non_neg_integer()) :: display_acc()
  defp add_context_with_folding(acc, ctx_lines, start_orig) do
    count = length(ctx_lines)

    if count > @fold_threshold do
      tail_offset = count - @context_lines
      fold_count = tail_offset - @context_lines
      fold_text = "  #{fold_count} unchanged lines"
      fold_meta = %{type: :fold, original_line: nil, fold_count: fold_count, word_changes: nil}

      acc
      |> add_context_rows(Enum.take(ctx_lines, @context_lines), start_orig)
      |> append_row(fold_text, fold_meta)
      |> add_context_rows(Enum.drop(ctx_lines, tail_offset), start_orig + tail_offset)
    else
      add_context_rows(acc, ctx_lines, start_orig)
    end
  end

  @spec add_context_rows(display_acc(), [String.t()], non_neg_integer()) :: display_acc()
  defp add_context_rows(acc, [], _original_line), do: acc

  defp add_context_rows(acc, [line | rest], original_line) do
    meta = %{type: :context, original_line: original_line, fold_count: nil, word_changes: nil}
    acc |> append_row(line, meta) |> add_context_rows(rest, original_line + 1)
  end

  @spec split_lines(String.t()) :: [String.t()]
  defp split_lines(""), do: []
  defp split_lines(content), do: String.split(content, "\n")
end
