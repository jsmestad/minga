defmodule MingaEditor.Renderer.GutterTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Renderer.Gutter

  @colors %MingaEditor.UI.Theme.Gutter{
    fg: 0x555555,
    current_fg: 0xBBC2CF,
    error_fg: 0xFF6C6B,
    warning_fg: 0xECBE7B,
    info_fg: 0x51AFEF,
    hint_fg: 0x555555
  }

  @git_colors %MingaEditor.UI.Theme.Git{
    added_fg: 0x98BE65,
    modified_fg: 0x51AFEF,
    deleted_fg: 0xFF6C6B
  }

  describe "total_width/1" do
    test "always includes sign column width" do
      assert Gutter.total_width(4) == 6
    end

    test "zero line number width still reserves sign column" do
      assert Gutter.total_width(0) == 2
    end
  end

  describe "sign_column_width/0" do
    test "returns 2" do
      assert Gutter.sign_column_width() == 2
    end
  end

  describe "render_sign/7" do
    test "renders error sign (diagnostic takes priority)" do
      diag_signs = %{5 => :error}
      result = Gutter.render_sign(0, 0, 5, diag_signs, %{}, @colors, @git_colors)
      assert is_tuple(result)
    end

    test "renders warning sign" do
      diag_signs = %{3 => :warning}
      result = Gutter.render_sign(0, 0, 3, diag_signs, %{}, @colors, @git_colors)
      assert is_tuple(result)
    end

    test "renders info sign" do
      diag_signs = %{1 => :info}
      result = Gutter.render_sign(0, 0, 1, diag_signs, %{}, @colors, @git_colors)
      assert is_tuple(result)
    end

    test "renders hint sign" do
      diag_signs = %{0 => :hint}
      result = Gutter.render_sign(0, 0, 0, diag_signs, %{}, @colors, @git_colors)
      assert is_tuple(result)
    end

    test "renders git added sign when no diagnostic" do
      git_signs = %{5 => :added}
      result = Gutter.render_sign(0, 0, 5, %{}, git_signs, @colors, @git_colors)
      assert is_tuple(result)
    end

    test "renders git modified sign when no diagnostic" do
      git_signs = %{5 => :modified}
      result = Gutter.render_sign(0, 0, 5, %{}, git_signs, @colors, @git_colors)
      assert is_tuple(result)
    end

    test "renders git deleted sign when no diagnostic" do
      git_signs = %{5 => :deleted}
      result = Gutter.render_sign(0, 0, 5, %{}, git_signs, @colors, @git_colors)
      assert is_tuple(result)
    end

    test "diagnostic takes priority over git sign on same line" do
      diag_signs = %{5 => :error}
      git_signs = %{5 => :added}
      result = Gutter.render_sign(0, 0, 5, diag_signs, git_signs, @colors, @git_colors)
      # Should render the diagnostic sign, not the git sign
      assert is_tuple(result)
    end

    test "renders empty space when no diagnostic or git sign" do
      diag_signs = %{5 => :error}
      result = Gutter.render_sign(0, 0, 10, diag_signs, %{}, @colors, @git_colors)
      assert is_tuple(result)
    end
  end

  describe "render_number/7" do
    test "renders line number with col_offset" do
      result = Gutter.render_number(0, 2, 5, 5, 4, :hybrid, @colors)
      assert is_tuple(result)
    end

    test "returns empty for :none style with zero width" do
      assert Gutter.render_number(0, 0, 5, 5, 0, :none, @colors) == []
    end

    test "returns empty for :none style with non-zero width" do
      # Regression: gutter must handle :none regardless of allocated width.
      # Previously crashed with FunctionClauseError in number_and_color/4
      # when a buffer (e.g. *Agent*) set line_numbers: :none but the
      # render path computed a non-zero gutter width.
      assert Gutter.render_number(0, 0, 5, 5, 4, :none, @colors) == []
    end
  end
end
