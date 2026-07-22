defmodule MingaEditor.WindowTest do
  use ExUnit.Case, async: true

  alias MingaEditor.UI.Popup.Active, as: PopupActive
  alias Minga.Popup.Rule, as: PopupRule
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.Window.RenderCache

  defp make_window do
    Window.new(1, spawn(fn -> :ok end), 24, 80)
  end

  describe "editor ownership" do
    test "window carries only bounded editor render observations" do
      window = make_window()

      assert %RenderCache{
               viewport_top: 0,
               viewport_left: 0,
               cursor_line: 0,
               cursor_col: 0,
               buffer_version: 0
             } = window.render_cache

      refute Map.has_key?(window.render_cache, :dirty_lines)
      refute Map.has_key?(window.render_cache, :retained_rows)
      refute Map.has_key?(window.render_cache, :resident_build)
      refute Map.has_key?(window.render_cache, :line_identity)
    end

    test "window source neither aliases nor calls renderer cache APIs" do
      source = File.read!("lib/minga_editor/window.ex")

      refute source =~ "MingaEditor.Renderer.WindowCache"
      refute source =~ "Renderer.WindowCache"
      refute source =~ "retained_rows"
      refute source =~ "resident_build"
      refute source =~ "snapshot_after_render"
    end

    test "synchronous observations update only viewport and bounded metadata" do
      window = %{make_window() | cursor: {7, 11}}
      viewport = window.viewport |> Viewport.put_top(5) |> Map.put(:left, 3)
      observed = Window.observe_render(window, viewport, 42)

      assert observed.viewport == viewport
      assert observed.render_cache == RenderCache.new(5, 3, 7, 11, 42)
      assert observed.content == window.content
      assert observed.fold_map == window.fold_map
    end
  end

  describe "viewport and input metadata" do
    test "resize clamps dimensions and preserves editor-owned cache type" do
      resized = Window.resize(make_window(), 0, 0)

      assert resized.viewport.rows == 1
      assert resized.viewport.cols == 1
      assert %RenderCache{} = resized.render_cache
    end

    test "scrolling and authoritative scroll markers remain editor-owned" do
      window = make_window() |> Window.scroll_viewport(5, 100) |> Window.mark_scroll_echo(5)
      marked = Window.mark_authoritative_scroll(window)

      assert window.viewport.top == 5
      assert window.scroll_echo_top == 5
      assert Window.authoritative_scroll_seq(marked) == 1
      assert %RenderCache{} = marked.render_cache
    end

    test "popup? reflects popup metadata" do
      window = make_window()
      refute Window.popup?(window)

      popup_window = %{window | popup_meta: PopupActive.new(PopupRule.new("*test*"), 1)}
      assert Window.popup?(popup_window)
    end
  end
end
