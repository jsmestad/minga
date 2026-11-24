defmodule MingaEditor.Agent.ReviewHighlightsTest do
  use ExUnit.Case, async: true

  alias Minga.Language.Highlight.Span
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.ReviewHighlights

  @before "defmodule A do\n  def old, do: 1\nend"
  @after_content "defmodule A do\n  def new, do: 2\nend"

  describe "plan/2" do
    test "a review of a file with a grammar wants one parse per side" do
      review = DiffReview.new("lib/a.ex", @before, @after_content)

      assert {:planned, store, requests} = ReviewHighlights.plan(ReviewHighlights.new(), review)

      assert Enum.sort(Enum.map(requests, fn {_key, language, source} -> {language, source} end)) ==
               Enum.sort([{"elixir", @before}, {"elixir", @after_content}])

      assert ReviewHighlights.sides(store) == %{old: nil, new: nil}
    end

    test "the same review terms plan nothing and keep the value" do
      review = DiffReview.new("lib/a.ex", @before, @after_content)
      {:planned, store, _requests} = ReviewHighlights.plan(ReviewHighlights.new(), review)

      assert ReviewHighlights.plan(store, review) == :unchanged
    end

    test "a file without a grammar wants no parse and renders flat" do
      review = DiffReview.new("notes.unknownext", "before", "after")

      assert {:planned, store, []} = ReviewHighlights.plan(ReviewHighlights.new(), review)
      assert ReviewHighlights.sides(store) == %{old: nil, new: nil}
      assert ReviewHighlights.plan(store, review) == :unchanged
    end

    test "a new post-image reuses the unchanged original's result and asks only for the new text" do
      review = DiffReview.new("lib/a.ex", @before, @after_content)
      {:planned, store, requests} = ReviewHighlights.plan(ReviewHighlights.new(), review)
      store = complete_all(store, requests)

      edited = DiffReview.new("lib/a.ex", @before, @after_content <> "\n# more")

      assert {:planned, store, [{_key, "elixir", source}]} =
               ReviewHighlights.plan(store, edited)

      assert source == @after_content <> "\n# more"
      assert %{old: {_old_key, ["keyword"], _spans}, new: nil} = ReviewHighlights.sides(store)
    end

    test "closing the review drops every result" do
      review = DiffReview.new("lib/a.ex", @before, @after_content)
      {:planned, store, requests} = ReviewHighlights.plan(ReviewHighlights.new(), review)
      store = complete_all(store, requests)

      assert {:planned, cleared, []} = ReviewHighlights.plan(store, nil)
      assert cleared == ReviewHighlights.new()
      assert ReviewHighlights.plan(cleared, nil) == :unchanged
    end
  end

  describe "complete/3" do
    test "installs a pending result and rejects results nobody waits for" do
      review = DiffReview.new("lib/a.ex", @before, @after_content)

      {:planned, store, [{key, _language, _source} | _rest]} =
        ReviewHighlights.plan(ReviewHighlights.new(), review)

      result = {:ready, ["keyword"], ReviewHighlights.pack_spans([Span.new(0, 9, 0)])}
      assert {:accepted, store} = ReviewHighlights.complete(store, key, result)
      assert ReviewHighlights.complete(store, key, result) == :stale
      assert ReviewHighlights.complete(store, {"elixir", "other"}, result) == :stale
    end
  end

  test "packed spans round-trip every field" do
    spans = [Span.new(0, 9, 3, 7, 1), Span.new(10, 4_000_000, 65_000, 0, 0)]
    assert spans |> ReviewHighlights.pack_spans() |> ReviewHighlights.unpack_spans() == spans
  end

  test "parser failures become an unavailable result" do
    for failure <- [:unsupported, :timeout, :unavailable, {:error, :boom}] do
      assert ReviewHighlights.pack_result(failure) == :unavailable
    end
  end

  test "the renderer snapshot omits the Editor-only planning identity" do
    review = DiffReview.new("lib/a.ex", @before, @after_content)
    {:planned, store, _requests} = ReviewHighlights.plan(ReviewHighlights.new(), review)

    snapshot = ReviewHighlights.render_snapshot(store)
    assert snapshot.source == nil
    assert ReviewHighlights.sides(snapshot) == ReviewHighlights.sides(store)
  end

  defp complete_all(store, requests) do
    Enum.reduce(requests, store, fn {key, _language, _source}, store ->
      result = {:ready, ["keyword"], ReviewHighlights.pack_spans([Span.new(0, 9, 0)])}
      {:accepted, store} = ReviewHighlights.complete(store, key, result)
      store
    end)
  end
end
