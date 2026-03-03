defmodule Minga.Editor.Renderer.GutterTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.Renderer.Gutter

  describe "total_width/2" do
    test "adds sign column width when diagnostics present" do
      line_number_w = 4
      assert Gutter.total_width(line_number_w, true) == 6
    end

    test "no sign column when no diagnostics" do
      line_number_w = 4
      assert Gutter.total_width(line_number_w, false) == 4
    end

    test "handles zero line number width" do
      assert Gutter.total_width(0, true) == 2
      assert Gutter.total_width(0, false) == 0
    end
  end

  describe "sign_column_width/0" do
    test "returns 2" do
      assert Gutter.sign_column_width() == 2
    end
  end

  describe "render_sign/4" do
    test "renders error sign" do
      signs = %{5 => :error}
      result = Gutter.render_sign(0, 0, 5, signs)
      assert is_binary(result)
      assert result != []
    end

    test "renders warning sign" do
      signs = %{3 => :warning}
      result = Gutter.render_sign(0, 0, 3, signs)
      assert is_binary(result)
    end

    test "renders info sign" do
      signs = %{1 => :info}
      result = Gutter.render_sign(0, 0, 1, signs)
      assert is_binary(result)
    end

    test "renders hint sign" do
      signs = %{0 => :hint}
      result = Gutter.render_sign(0, 0, 0, signs)
      assert is_binary(result)
    end

    test "renders empty space when line has no diagnostic" do
      signs = %{5 => :error}
      result = Gutter.render_sign(0, 0, 10, signs)
      assert is_binary(result)
    end

    test "returns empty list when signs map is empty" do
      assert Gutter.render_sign(0, 0, 5, %{}) == []
    end
  end

  describe "render_number/6" do
    test "renders line number with col_offset" do
      result = Gutter.render_number(0, 2, 5, 5, 4, :hybrid)
      assert is_binary(result)
    end

    test "returns empty for :none style with zero width" do
      assert Gutter.render_number(0, 0, 5, 5, 0, :none) == []
    end
  end
end
