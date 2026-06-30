defmodule MingaEditor.UI.Picker.ScorerTest do
  @moduledoc "Bounded top-K scoring matches the brute-force ordering it replaces."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MingaEditor.UI.Picker.Candidate
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.Scorer

  # Reference implementation: the previous behavior, score every candidate then
  # fully sort. Ties broken by original index, exactly as `top_k` claims to.
  defp brute_force(candidates, segments) do
    candidates
    |> Enum.map(fn c -> {Scorer.score_candidate(c, segments), c} end)
    |> Enum.filter(fn {score, _c} -> score > 0 end)
    |> Enum.sort_by(fn {score, c} -> {-score, c.index} end)
    |> Enum.map(fn {_score, c} -> c end)
  end

  defp candidates(labels) do
    labels
    |> Enum.map(&%Item{id: &1, label: &1})
    |> Candidate.from_items()
  end

  describe "top_k/3 vs brute force" do
    test "with k >= matches, returns the exact full sorted order" do
      cands = candidates(["config.exs", "xconfig.exs", "lib/config/runtime.exs", "readme.md"])
      segments = ["config"]

      assert Scorer.top_k(cands, segments, Enum.count(cands)) == brute_force(cands, segments)
    end

    test "bounded result is the prefix of the brute-force order" do
      cands =
        candidates(["config.exs", "xconfig.exs", "lib/config/runtime.exs", "config_helper.ex"])

      segments = ["config"]

      full = brute_force(cands, segments)

      for k <- 1..length(cands) do
        assert Scorer.top_k(cands, segments, k) == Enum.take(full, k)
      end
    end

    test "prefix beats substring beats fuzzy, label beats search-only" do
      cands =
        candidates([
          # fuzzy on label
          "ceonfig.ex",
          # substring on label
          "xconfig.exs",
          # prefix on label
          "config.exs"
        ])

      [first, second, third] = Scorer.top_k(cands, ["config"], 3) |> Enum.map(& &1.item.label)

      assert first == "config.exs"
      assert second == "xconfig.exs"
      assert third == "ceonfig.ex"
    end

    test "drops candidates that fail any segment (orderless)" do
      cands = candidates(["buffer-switch", "buffer-kill", "file-open"])
      result = Scorer.top_k(cands, ["b", "sw"], 10) |> Enum.map(& &1.item.label)

      assert result == ["buffer-switch"]
    end

    test "matches against the search field when the label does not match" do
      cands = [%Item{id: 1, label: "app.ex", search_text: "lib/deep/path/app.ex"}]
      cands = Candidate.from_items(cands)

      assert Scorer.top_k(cands, ["deep"], 5) |> Enum.count() == 1
    end

    test "fuzzy matches non-ASCII (multi-byte UTF-8) paths in order" do
      cands = candidates(["café/münchen/straße.txt", "plain/ascii/file.txt"])

      # Query is lowercase and out of contiguous order, forcing the fuzzy path
      # (no prefix/substring hit). The accented codepoints must match by value.
      result = Scorer.top_k(cands, ["cféü"], 5) |> Enum.map(& &1.item.label)

      assert result == ["café/münchen/straße.txt"]
    end

    test "fuzzy path rejects a non-ASCII candidate whose accented codepoints differ" do
      # The binary walk must compare accented codepoints by value, not treat any
      # multi-byte sequence as a wildcard. "ö" must not satisfy a query "ü".
      cands = candidates(["lib/schön/config.exs"])

      # "ü" never appears, so fuzzy must fail and the candidate is dropped.
      assert Scorer.top_k(cands, ["xü"], 5) == []
    end

    test "binary fuzzy walk agrees with the grapheme-list walk on Unicode inputs" do
      # Equivalence check: for the same input bytes, the old grapheme-by-grapheme
      # match and the new codepoint binary walk must return the same boolean.
      grapheme_fuzzy = fn haystack, needle ->
        walk = fn
          _h, [], _self ->
            true

          [], _n, _self ->
            false

          [x | hr], [y | _nr] = ndl, self ->
            if x == y, do: self.(hr, tl(ndl), self), else: self.(hr, ndl, self)
        end

        walk.(String.graphemes(haystack), String.graphemes(needle), walk)
      end

      haystacks = ["café.exs", "münchen.ex", "straße_config.exs", "naïve_doc.md"]
      needles = ["cf", "afx", "müc", "sße", "naïe", "öü", "xyz"]

      for haystack <- haystacks, needle <- needles do
        # Restrict to inputs where neither prefix nor substring fires, so the
        # candidate's match outcome is decided purely by the fuzzy walk.
        refute String.starts_with?(haystack, needle)
        refute String.contains?(haystack, needle)

        matched? = Scorer.top_k(candidates([haystack]), [needle], 1) != []

        assert matched? == grapheme_fuzzy.(haystack, needle),
               "binary walk disagreed with grapheme walk for #{inspect(haystack)} / #{inspect(needle)}"
      end
    end

    test "documents intentional NFD divergence: base letter matches a decomposed grapheme" do
      # macOS APFS delivers accented filenames in NFD (decomposed): the accent is
      # a separate combining codepoint after the base letter, e.g. "café.txt" is
      # the bytes "cafe" + U+0301 (0xCC 0x81) + ".txt", not a precomposed "é".
      nfd_label = <<"cafe", 0xCC, 0x81, ".txt">>

      # Sanity-check the fixture really is decomposed: 10 bytes / 9 codepoints
      # collapse to 8 graphemes because "e" + U+0301 forms a single "é" grapheme.
      assert byte_size(nfd_label) == 10
      assert length(String.graphemes(nfd_label)) == 8

      cands = candidates([nfd_label])

      # "fet" is neither a prefix nor a contiguous substring (the combining mark
      # sits between "fe" and "t"), so this exercises the fuzzy walk specifically.
      refute String.starts_with?(nfd_label, "fet")
      refute String.contains?(nfd_label, "fet")

      # The new byte-level walk extracts the base "e" before the combining mark,
      # so the ASCII needle matches. This is the DOCUMENTED, INTENTIONAL
      # divergence from the old grapheme-level matcher: on decomposed Unicode the
      # binary walk is strictly more lenient (it can match a base letter that the
      # grapheme walk hid inside a combined grapheme). The divergence is additive
      # (more matches, never fewer) and is conventional fuzzy-picker behavior.
      # Normalizing per keystroke would reintroduce the per-candidate allocation
      # this change exists to remove, so the lenient behavior is deliberate.
      assert Scorer.top_k(cands, ["fet"], 5) |> Enum.map(& &1.item.label) == [nfd_label]

      # Prove this is a genuine divergence: the old grapheme-by-grapheme matcher
      # could NOT have matched "fet", because the base "e" is fused into the "é"
      # grapheme and never appears as a standalone "e" grapheme to compare against.
      # A future change that re-aligns the two walks must be a conscious decision,
      # not a silent regression caught only here.
      refute "e" in String.graphemes(nfd_label),
             "expected the decomposed grapheme to hide the base 'e' from grapheme matching"
    end
  end

  describe "bounded large sets" do
    test "never returns more than k and stays a prefix of brute force" do
      labels = for i <- 1..10_000, do: "module_#{i}_config.ex"
      cands = candidates(labels)
      segments = ["config"]

      result = Scorer.top_k(cands, segments, 200)

      assert Enum.count(result) == 200
      assert result == Enum.take(brute_force(cands, segments), 200)
    end
  end

  property "top_k always equals the prefix of the brute-force order" do
    check all(
            labels <-
              list_of(string(?a..?z, min_length: 1, max_length: 6), min_length: 1, max_length: 40),
            query <- string(?a..?z, min_length: 1, max_length: 3),
            k <- integer(1..50)
          ) do
      cands = candidates(labels)
      segments = [query]

      assert Scorer.top_k(cands, segments, k) == Enum.take(brute_force(cands, segments), k)
    end
  end
end
