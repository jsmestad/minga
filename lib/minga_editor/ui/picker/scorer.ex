defmodule MingaEditor.UI.Picker.Scorer do
  @moduledoc """
  Bounded top-K scoring over precomputed picker candidates.

  Scores each candidate against the query segments using its precomputed,
  pre-lowered label/search fields and keeps only the best `k` results without
  sorting the full match set. This is what keeps the picker responsive when a
  source has tens of thousands of candidates: instead of scoring, fully sorting,
  and computing match positions for every candidate on each keystroke, we score
  once and retain a small bounded window.

  Ordering reproduces the previous brute-force order exactly: higher score
  first, ties broken by the candidate's original `index` (stable). So for
  `k >= match_count` the result is identical to filtering and fully sorting.
  """

  alias MingaEditor.UI.Picker.Candidate

  @label_match_bonus 200
  @prefix_score 300
  @basename_prefix_score 280
  @path_boundary_score 250
  @substring_score 200
  @fuzzy_score 100
  @max_length_bonus 50

  @doc """
  Returns the best `k` candidates for the given lowercase query `segments`,
  ordered best-first. Candidates that do not match every segment are dropped.

  Selection is bounded: a running window of at most `k` entries is maintained
  while scanning, so the full match list is never sorted.
  """
  @spec top_k([Candidate.t()], [String.t()], pos_integer()) :: [Candidate.t()]
  def top_k(candidates, segments, k) when is_list(candidates) and is_list(segments) and k > 0 do
    candidates
    |> Enum.reduce({0, []}, fn candidate, {count, kept} ->
      case score_candidate(candidate, segments) do
        score when score > 0 -> bounded_insert(kept, count, {score, candidate}, k)
        _zero -> {count, kept}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.map(fn {_score, candidate} -> candidate end)
  end

  @doc """
  Scores a single candidate against the query segments. Returns `0` when any
  segment fails to match. Mirrors the picker's historical scoring: a label
  match outranks a search-field-only match, prefix beats substring beats fuzzy,
  and shorter labels get a small bonus.
  """
  @spec score_candidate(Candidate.t(), [String.t()]) :: non_neg_integer()
  def score_candidate(%Candidate{} = candidate, segments) do
    segment_scores =
      Enum.map(segments, fn segment ->
        label_score = score_segment(candidate.norm_label, segment)

        if label_score > 0 do
          label_score + @label_match_bonus
        else
          score_segment(candidate.norm_search, segment)
        end
      end)

    if Enum.any?(segment_scores, &(&1 == 0)) do
      0
    else
      Enum.sum(segment_scores) + max(0, @max_length_bonus - candidate.label_length)
    end
  end

  # Maintain `kept` as a list sorted worst-first so the weakest entry is the head
  # and cheap to evict once the window exceeds `k`.
  @spec bounded_insert(
          [{non_neg_integer(), Candidate.t()}],
          non_neg_integer(),
          {non_neg_integer(), Candidate.t()},
          pos_integer()
        ) ::
          {non_neg_integer(), [{non_neg_integer(), Candidate.t()}]}
  defp bounded_insert(kept, count, entry, k) do
    kept = insert_sorted(kept, entry)

    if count + 1 > k do
      [_evicted | rest] = kept
      {k, rest}
    else
      {count + 1, kept}
    end
  end

  @spec insert_sorted([{non_neg_integer(), Candidate.t()}], {non_neg_integer(), Candidate.t()}) ::
          [{non_neg_integer(), Candidate.t()}]
  defp insert_sorted([], entry), do: [entry]

  defp insert_sorted([head | tail] = list, entry) do
    if better?(entry, head) do
      [head | insert_sorted(tail, entry)]
    else
      [entry | list]
    end
  end

  # Higher score wins; ties broken by lower original index (stable order).
  @spec better?({non_neg_integer(), Candidate.t()}, {non_neg_integer(), Candidate.t()}) ::
          boolean()
  defp better?({score_a, cand_a}, {score_b, cand_b}) do
    score_a > score_b or (score_a == score_b and cand_a.index < cand_b.index)
  end

  @spec score_segment(String.t(), String.t()) :: non_neg_integer()
  defp score_segment(text, segment) do
    if String.starts_with?(text, segment) do
      @prefix_score
    else
      score_non_prefix_segment(text, segment)
    end
  end

  @spec score_non_prefix_segment(String.t(), String.t()) :: non_neg_integer()
  defp score_non_prefix_segment(text, segment) do
    if String.contains?(text, segment) do
      score_substring_with_boundary(text, segment)
    else
      score_fuzzy_segment(text, segment)
    end
  end

  @spec score_substring_with_boundary(String.t(), String.t()) :: non_neg_integer()
  defp score_substring_with_boundary(text, segment) do
    basename_start =
      case :binary.match(text, "/") do
        :nomatch ->
          0

        _ ->
          byte_size(text) - byte_size(Path.basename(text))
      end

    cond do
      basename_start > 0 and
          String.starts_with?(
            binary_part(text, basename_start, byte_size(text) - basename_start),
            segment
          ) ->
        @basename_prefix_score

      matches_after_separator?(text, segment) ->
        @path_boundary_score

      true ->
        @substring_score
    end
  end

  @spec matches_after_separator?(String.t(), String.t()) :: boolean()
  defp matches_after_separator?(text, segment) do
    case :binary.match(text, "/" <> segment) do
      {_, _} -> true
      :nomatch -> false
    end
  end

  @spec score_fuzzy_segment(String.t(), String.t()) :: non_neg_integer()
  defp score_fuzzy_segment(text, segment) do
    if fuzzy_match?(text, segment) do
      @fuzzy_score
    else
      0
    end
  end

  # Check if all characters in `needle` appear in order in `haystack`.
  #
  # Walks both binaries one Unicode codepoint at a time via `<<c::utf8, ...>>`
  # instead of materializing a grapheme list per candidate. This is the picker's
  # per-keystroke hot path: with 100K candidates, `String.graphemes/1` on each
  # full path allocated millions of single-codepoint binaries and pressured the
  # Editor process's GC. The binary walk extracts one codepoint without building
  # a list (a single-byte comparison for ASCII, still correct for multi-byte
  # UTF-8). For single-codepoint graphemes (the norm for file paths) this is
  # identical to the previous grapheme-by-grapheme comparison.
  @spec fuzzy_match?(String.t(), String.t()) :: boolean()
  defp fuzzy_match?(_haystack, <<>>), do: true
  defp fuzzy_match?(<<>>, _needle), do: false

  defp fuzzy_match?(<<c::utf8, h_rest::binary>>, <<c::utf8, n_rest::binary>>) do
    fuzzy_match?(h_rest, n_rest)
  end

  defp fuzzy_match?(<<_c::utf8, h_rest::binary>>, needle) do
    fuzzy_match?(h_rest, needle)
  end
end
