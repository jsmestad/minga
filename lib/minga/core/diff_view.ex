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

    {display_lines, metadata, hunk_indices} =
      Enum.reduce(regions, {[], [], []}, fn
        {:context, ctx_lines, start_orig}, {lines_acc, meta_acc, hunk_acc} ->
          add_context_with_folding(lines_acc, meta_acc, hunk_acc, ctx_lines, start_orig)

        {:hunk, hunk_lines_list}, {lines_acc, meta_acc, hunk_acc} ->
          display_line_idx = length(lines_acc)
          add_hunk_lines(lines_acc, meta_acc, hunk_acc, hunk_lines_list, display_line_idx)
      end)

    text = Enum.join(display_lines, "\n")

    %{
      text: text,
      line_metadata: metadata,
      hunk_lines: Enum.reverse(hunk_indices)
    }
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

    {display_lines, metadata, hunk_indices} =
      Enum.reduce(regions, {[], [], []}, fn
        {:context, ctx_lines, start_orig}, {lines_acc, meta_acc, hunk_acc} ->
          add_context_side_by_side(
            lines_acc,
            meta_acc,
            hunk_acc,
            ctx_lines,
            start_orig,
            pane_width
          )

        {:hunk, hunk}, {lines_acc, meta_acc, hunk_acc} ->
          display_line_idx = length(lines_acc)

          add_hunk_side_by_side(
            lines_acc,
            meta_acc,
            hunk_acc,
            hunk,
            current_lines,
            display_line_idx,
            pane_width
          )
      end)

    %{
      text: Enum.join(display_lines, "\n"),
      line_metadata: metadata,
      hunk_lines: Enum.reverse(hunk_indices)
    }
  end

  # ── Private ────────────────────────────────────────────────────────────

  @spec add_hunk_side_by_side(
          [String.t()],
          [line_meta()],
          [non_neg_integer()],
          Diff.hunk(),
          [String.t()],
          non_neg_integer(),
          pos_integer()
        ) :: {[String.t()], [line_meta()], [non_neg_integer()]}
  defp add_hunk_side_by_side(
         lines_acc,
         meta_acc,
         hunk_acc,
         hunk,
         current_lines,
         display_line_idx,
         pane_width
       ) do
    side_lines = build_hunk_side_by_side(hunk, current_lines)
    hunk_acc = [display_line_idx + length(side_lines) - 1 | hunk_acc]
    {hunk_text, hunk_meta} = encode_side_by_side_lines(side_lines, pane_width)
    {lines_acc ++ hunk_text, meta_acc ++ hunk_meta, hunk_acc}
  end

  @spec add_context_side_by_side(
          [String.t()],
          [line_meta()],
          [non_neg_integer()],
          [String.t()],
          non_neg_integer(),
          pos_integer()
        ) :: {[String.t()], [line_meta()], [non_neg_integer()]}
  defp add_context_side_by_side(lines, meta, hunks, ctx_lines, start_orig, pane_width) do
    count = length(ctx_lines)

    if count > @fold_threshold do
      add_folded_context_side_by_side(lines, meta, hunks, ctx_lines, start_orig, pane_width)
    else
      side_lines = context_side_by_side_lines(ctx_lines, start_orig)
      {text, text_meta} = encode_side_by_side_lines(side_lines, pane_width)
      {lines ++ text, meta ++ text_meta, hunks}
    end
  end

  @spec add_folded_context_side_by_side(
          [String.t()],
          [line_meta()],
          [non_neg_integer()],
          [String.t()],
          non_neg_integer(),
          pos_integer()
        ) :: {[String.t()], [line_meta()], [non_neg_integer()]}
  defp add_folded_context_side_by_side(lines, meta, hunks, ctx_lines, start_orig, pane_width) do
    count = length(ctx_lines)
    head = Enum.take(ctx_lines, @context_lines)
    tail = Enum.take(ctx_lines, -@context_lines)
    fold_count = count - @context_lines * 2
    tail_start = start_orig + count - @context_lines

    side_lines =
      context_side_by_side_lines(head, start_orig) ++
        [fold_side_by_side_line(fold_count)] ++ context_side_by_side_lines(tail, tail_start)

    {text, text_meta} = encode_side_by_side_lines(side_lines, pane_width)
    {lines ++ text, meta ++ text_meta, hunks}
  end

  @spec context_side_by_side_lines([String.t()], non_neg_integer()) :: [side_by_side_line()]
  defp context_side_by_side_lines(ctx_lines, start_orig) do
    ctx_lines
    |> Enum.with_index(start_orig)
    |> Enum.map(fn {line, idx} ->
      %{
        left: line,
        right: line,
        left_type: :context,
        right_type: :context,
        original_line: idx,
        fold_count: nil,
        left_word_changes: nil,
        right_word_changes: nil
      }
    end)
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

  @spec encode_side_by_side_lines([side_by_side_line()], pos_integer()) ::
          {[String.t()], [line_meta()]}
  defp encode_side_by_side_lines(side_lines, pane_width) do
    side_lines
    |> Enum.map(&format_side_by_side_line(&1, pane_width))
    |> Enum.unzip()
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

    {hunk_text, hunk_meta} =
      Enum.map_reduce(hunk_lines_list, [], fn {text, type, orig_line, word_changes}, meta_acc ->
        meta = %{
          type: type,
          original_line: orig_line,
          fold_count: nil,
          word_changes: word_changes
        }

        {text, [meta | meta_acc]}
      end)

    {lines_acc ++ hunk_text, meta_acc ++ Enum.reverse(hunk_meta), hunk_acc}
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

    if last_end < length(current_lines) do
      ctx = Enum.slice(current_lines, last_end..(length(current_lines) - 1))
      regions ++ [{:context, ctx, last_end}]
    else
      regions
    end
  end

  @spec build_hunk_display(Diff.hunk(), [String.t()], [String.t()]) :: [
          {String.t(), :added | :removed | :context, non_neg_integer() | nil,
           [Diff.char_range()] | nil}
        ]
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
    pair_modified_lines(old_lines, new_lines, length(old_lines), length(new_lines))
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
          %{type: :context, original_line: idx, fold_count: nil, word_changes: nil}
        end)

      fold_meta = [%{type: :fold, original_line: nil, fold_count: fold_count, word_changes: nil}]

      tail_start = start_orig + count - @context_lines

      tail_meta =
        Enum.with_index(tail, tail_start)
        |> Enum.map(fn {_line, idx} ->
          %{type: :context, original_line: idx, fold_count: nil, word_changes: nil}
        end)

      fold_text = "  #{fold_count} unchanged lines"

      {lines ++ head ++ [fold_text] ++ tail, meta ++ head_meta ++ fold_meta ++ tail_meta, hunks}
    else
      ctx_meta =
        Enum.with_index(ctx_lines, start_orig)
        |> Enum.map(fn {_line, idx} ->
          %{type: :context, original_line: idx, fold_count: nil, word_changes: nil}
        end)

      {lines ++ ctx_lines, meta ++ ctx_meta, hunks}
    end
  end

  @spec split_lines(String.t()) :: [String.t()]
  defp split_lines(""), do: []
  defp split_lines(content), do: String.split(content, "\n")
end
