defmodule MingaEditor.RenderModel.Window.ReviewBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.Core.WidthOracle.Monospace
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Renderer.RenderWindow
  alias MingaEditor.Renderer.ReviewObservation
  alias MingaEditor.Renderer.State, as: RendererState
  alias MingaEditor.RenderModel.Window.ReviewBuilder
  alias MingaEditor.RenderModel.Window.ReviewLayout
  alias MingaEditor.RenderPipeline.WindowIntent
  alias MingaEditor.UI.Theme
  alias MingaEditor.Window

  test "a wrapped review has a real body viewport and scrolls within retained read-only rows" do
    preview =
      Preview.new()
      |> Preview.set_diff(
        DiffReview.new("selected.ex", "before", String.duplicate("界e\u0301 ", 40))
      )
      |> Preview.scroll_to_top()

    window = render_window()
    rects = %{content: {2, 4, 16, 3}, total: {2, 4, 16, 4}}
    layout = ReviewLayout.new(16, %Monospace{}, Theme.get!(:minga_default), 4)
    scope = {1, nil}
    assert {:ok, first, window} = ReviewBuilder.build(window, preview, rects, layout, scope)
    assert first.content_kind == :agent_review
    refute first.cursor_visible
    assert first.full_refresh
    assert first.geometry.content_rect == {2, 4, 16, 3}
    assert first.geometry.text_rect == {2, 4, 15, 3}
    assert first.geometry.clip_rect == {2, 4, 15, 3}
    assert first.geometry.viewport.rows == 3
    assert first.geometry.viewport.cols == 15
    assert window.viewport.reserved == 0
    assert first.row_store_mode == {:resident, length(first.rows)}
    assert Enum.any?(first.rows, &String.contains?(&1.text, "界e\u0301"))

    for {row, rank} <- Enum.with_index(first.rows) do
      assert row.buf_line == rank
    end

    offset =
      Enum.find_index(first.rows, &(&1.visual_index == 1 and String.contains?(&1.text, "界")))

    {:ok, preview} =
      Preview.observe_review(preview, Preview.review_source(preview), length(first.rows), 3)

    preview = Preview.scroll_down(preview, offset)

    assert {:ok, scrolled, window} = ReviewBuilder.build(window, preview, rects, layout, scope)
    assert scrolled.geometry.viewport.top == offset
    assert scrolled.geometry.viewport.visual_row_offset == 0
    refute scrolled.full_refresh
    assert scrolled.row_delta == nil
    assert :erts_debug.same(first.rows, scrolled.rows)
    assert scrolled.scroll_seq > first.scroll_seq

    carrier =
      Window.new_agent_chat(1, 3, 16)
      |> Window.show_agent_body(:review)
      |> WindowIntent.from_window()

    next_frame = RenderWindow.materialize(1, carrier, window.render_cache)
    assert ReviewObservation.from_window(next_frame) == nil
  end

  test "the shared text aperture retains boundary Unicode independently of scrollbar visibility" do
    text = String.duplicate("Shipping notes with e\u0301 and 界. ", 20)
    preview = Preview.set_diff(Preview.new(), DiffReview.new("checkout.ex", "before", text))

    for pane_width <- [1, 12, 60, 140], height <- [2, 500] do
      text_width = max(pane_width - 1, 1)
      rects = %{content: {2, 4, pane_width, height}, total: {2, 4, pane_width, height}}
      layout = ReviewLayout.new(pane_width, %Monospace{}, Theme.get!(:minga_default), 4)

      assert {:ok, model, _window} =
               ReviewBuilder.build(render_window(), preview, rects, layout, {1, nil})

      assert model.geometry.content_rect == {2, 4, pane_width, height}
      assert model.geometry.text_rect == {2, 4, text_width, height}
      assert model.geometry.clip_rect == {2, 4, text_width, height}
      assert model.geometry.viewport.cols == text_width
      assert model.geometry.viewport.rows == height
      assert [%{kind: :text, rect: {2, 4, ^text_width, ^height}}] = model.geometry.hit_regions
      assert String.contains?(Enum.map_join(model.rows, & &1.text), "+ " <> text)
    end
  end

  test "an unavailable review is explicit and an unfitted body publishes no geometry" do
    window = render_window()
    layout = ReviewLayout.new(16, %Monospace{}, Theme.get!(:minga_default), 4)
    rects = %{content: {2, 4, 16, 3}, total: {2, 4, 16, 4}}
    preview = Preview.set_diff(Preview.new(), DiffReview.new("selected.ex", "before", "after"))

    assert {:error, :review_unavailable} =
             ReviewBuilder.build(window, Preview.new(), rects, layout, {1, nil})

    assert {:error, :review_unavailable} =
             ReviewBuilder.build(window, preview, rects, layout, nil)

    assert :not_visible =
             ReviewBuilder.build(
               window,
               preview,
               %{rects | content: {2, 4, 0, 3}},
               layout,
               {1, nil}
             )

    assert :not_visible =
             ReviewBuilder.build(
               window,
               preview,
               %{rects | content: {2, 4, 16, 0}},
               layout,
               {1, nil}
             )

    assert ReviewObservation.from_window(window) == nil
  end

  test "navigation and a non-final decision name the exact conflict in the retained review" do
    review =
      DiffReview.from_fork_snapshot("note.txt", {self(), 2, 1}, [
        {:conflict, ["Agent A"], ["Human A"], []},
        {:resolved, ["unchanged"]},
        {:conflict, ["Agent B"], ["Human B"], []}
      ])

    preview = Preview.set_diff(Preview.new(), review)
    rects = %{content: {2, 4, 60, 30}, total: {2, 4, 60, 30}}
    layout = ReviewLayout.new(60, %Monospace{}, Theme.get!(:minga_default), 4)
    scope = {1, nil}

    assert {:ok, first, window} =
             ReviewBuilder.build(render_window(), preview, rects, layout, scope)

    assert first.accessibility_label =~ "Conflict 1 selected"
    assert Enum.any?(first.rows, &String.starts_with?(&1.text, "Conflict 1 "))
    assert Enum.any?(first.rows, &String.starts_with?(&1.text, "Conflict 2 "))

    next = Preview.navigate_hunk(preview, :next)
    assert {:ok, navigated, window} = ReviewBuilder.build(window, next, rects, layout, scope)
    assert navigated.accessibility_label =~ "Conflict 2 selected"
    assert navigated.row_delta == nil

    decided = Preview.replace_diff(next, DiffReview.accept_current(Preview.diff_review(next)))
    assert {:ok, advanced, _window} = ReviewBuilder.build(window, decided, rects, layout, scope)
    assert advanced.accessibility_label =~ "Conflict 1 selected"
    assert DiffReview.resolution_at(Preview.diff_review(decided), 1) == :accepted
  end

  defp render_window do
    window = Window.new_agent_chat(1, 3, 16) |> Window.show_agent_body(:review)
    cache = RendererState.window_cache(RendererState.new([]), 1)
    RenderWindow.materialize(1, WindowIntent.from_window(window), cache)
  end
end
