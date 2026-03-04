defmodule Minga.Editor.Renderer.GutterTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.Renderer.Gutter

  @colors %Minga.Theme.Gutter{
    fg: 0x555555,
    current_fg: 0xBBC2CF,
    error_fg: 0xFF6C6B,
    warning_fg: 0xECBE7B,
    info_fg: 0x51AFEF,
    hint_fg: 0x555555
  }

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

  describe "render_sign/5" do
    test "renders error sign" do
      signs = %{5 => :error}
      result = Gutter.render_sign(0, 0, 5, signs, @colors)
      assert is_binary(result)
      assert result != []
    end

    test "renders warning sign" do
      signs = %{3 => :warning}
      result = Gutter.render_sign(0, 0, 3, signs, @colors)
      assert is_binary(result)
    end

    test "renders info sign" do
      signs = %{1 => :info}
      result = Gutter.render_sign(0, 0, 1, signs, @colors)
      assert is_binary(result)
    end

    test "renders hint sign" do
      signs = %{0 => :hint}
      result = Gutter.render_sign(0, 0, 0, signs, @colors)
      assert is_binary(result)
    end

    test "renders empty space when line has no diagnostic" do
      signs = %{5 => :error}
      result = Gutter.render_sign(0, 0, 10, signs, @colors)
      assert is_binary(result)
    end

    test "returns empty list when signs map is empty" do
      assert Gutter.render_sign(0, 0, 5, %{}, @colors) == []
    end
  end

  describe "render_number/7" do
    test "renders line number with col_offset" do
      result = Gutter.render_number(0, 2, 5, 5, 4, :hybrid, @colors)
      assert is_binary(result)
    end

    test "returns empty for :none style with zero width" do
      assert Gutter.render_number(0, 0, 5, 5, 0, :none, @colors) == []
    end
  end
end
