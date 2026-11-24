defmodule MingaEditor.Agent.ReviewHighlightParserTest do
  # Opens the native parser Port; keep it serialized with other OS-process tests.
  use ExUnit.Case, async: false

  @moduletag :heavy
  @moduletag timeout: 20_000

  alias Minga.Core.WidthOracle.Monospace
  alias Minga.Parser.Manager
  alias Minga.RenderModel.Window.RowSlotAllocator
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.ReviewHighlights
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.RenderModel.Window.ReviewLayout
  alias MingaEditor.RenderModel.Window.ReviewProjection
  alias MingaEditor.UI.Theme

  @before "defmodule Demo do\n  def old, do: :old\n  def keep, do: 1\nend\n"
  @after_content "defmodule Demo do\n  def new, do: :new\n  def keep, do: 1\nend\n"

  test "the real Elixir grammar colors removed, added, and context lines in the review" do
    server = Module.concat(__MODULE__, "Parser#{System.unique_integer([:positive])}")
    start_supervised!({Manager, name: server})

    review = DiffReview.new("lib/demo.ex", @before, @after_content)
    {:planned, store, requests} = ReviewHighlights.plan(ReviewHighlights.new(), review)

    store =
      Enum.reduce(requests, store, fn {key, language, source}, store ->
        result =
          language
          |> Manager.highlight_source(source, server: server, timeout: 10_000)
          |> ReviewHighlights.pack_result()

        assert {:ready, _names, _spans} = result
        {:accepted, store} = ReviewHighlights.complete(store, key, result)
        store
      end)

    theme = Theme.get!(:minga_default)
    layout = ReviewLayout.new(80, %Monospace{}, theme, 4, ReviewHighlights.sides(store))
    preview = Preview.set_diff(Preview.new(), review)

    {:ok, projection, _allocator, nil} =
      ReviewProjection.refresh(nil, preview, :scope, layout, RowSlotAllocator.new(), 1)

    for text <- ["-   def old, do: :old", "+   def new, do: :new", "    def keep, do: 1"] do
      row = Enum.find(projection.rows, &(&1.text == text))
      assert row, "missing review row #{inspect(text)}"

      code_colors =
        row.spans |> Enum.filter(&(&1.start_col >= 2 and &1.fg != 0)) |> Enum.map(& &1.fg)

      assert [_, _ | _] = Enum.uniq(code_colors), "#{inspect(text)} rendered flat"
    end
  end
end
