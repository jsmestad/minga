defmodule MingaEditor.Renderer.GutterTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Decorations
  alias Minga.Core.Decorations.LineAnnotation
  alias MingaEditor.Renderer.Context
  alias MingaEditor.Renderer.Gutter
  alias MingaEditor.Viewport

  @colors %MingaEditor.UI.Theme.Gutter{
    fg: 0x555555,
    current_fg: 0xBBC2CF,
    error_fg: 0xFF6C6B,
    warning_fg: 0xECBE7B,
    info_fg: 0x51AFEF,
    hint_fg: 0x555555,
    fold_fg: 0x555555
  }

  @git_colors %MingaEditor.UI.Theme.Git{
    added_fg: 0x98BE65,
    modified_fg: 0x51AFEF,
    deleted_fg: 0xFF6C6B
  }

  defp sign_ctx(overrides) do
    %Context{
      viewport: Viewport.new(24, 80),
      gutter_w: 4,
      content_w: 76,
      diagnostic_signs: Map.get(overrides, :diagnostic_signs, %{}),
      git_signs: Map.get(overrides, :git_signs, %{}),
      gutter_colors: @colors,
      git_colors: @git_colors,
      decorations: Map.get(overrides, :decorations, %Decorations{})
    }
    |> Gutter.SignContext.from_render_context()
  end

  defp decode_draw({row, col, text, style}) do
    %{row: row, col: col, text: text, fg: style.fg, bg: style.bg}
  end

  defp assert_sign(draw, expected_text, expected_fg) do
    assert %{text: ^expected_text, fg: ^expected_fg} = decode_draw(draw)
  end

  describe "total_width/1" do
    test "always includes sign and fold column width" do
      assert Gutter.total_width(4) == 7
    end

    test "zero line number width still reserves sign and fold columns" do
      assert Gutter.total_width(0) == 3
    end
  end

  describe "sign_column_width/0" do
    test "returns 2" do
      assert Gutter.sign_column_width() == 2
    end
  end

  describe "fold_column_offset/0" do
    test "returns the column after the sign column" do
      assert Gutter.fold_column_offset() == 2
    end
  end

  describe "render_sign/4" do
    test "renders error sign (diagnostic takes priority)" do
      result = Gutter.render_sign(0, 0, 5, sign_ctx(%{diagnostic_signs: %{5 => :error}}))
      assert_sign(result, "E ", @colors.error_fg)
    end

    test "renders warning sign" do
      result = Gutter.render_sign(0, 0, 3, sign_ctx(%{diagnostic_signs: %{3 => :warning}}))
      assert_sign(result, "W ", @colors.warning_fg)
    end

    test "renders info sign" do
      result = Gutter.render_sign(0, 0, 1, sign_ctx(%{diagnostic_signs: %{1 => :info}}))
      assert_sign(result, "I ", @colors.info_fg)
    end

    test "renders hint sign" do
      result = Gutter.render_sign(0, 0, 0, sign_ctx(%{diagnostic_signs: %{0 => :hint}}))
      assert_sign(result, "H ", @colors.hint_fg)
    end

    test "renders git added sign when no diagnostic" do
      result = Gutter.render_sign(0, 0, 5, sign_ctx(%{git_signs: %{5 => :added}}))
      assert_sign(result, "▎ ", @git_colors.added_fg)
    end

    test "renders git modified sign when no diagnostic" do
      result = Gutter.render_sign(0, 0, 5, sign_ctx(%{git_signs: %{5 => :modified}}))
      assert_sign(result, "▎ ", @git_colors.modified_fg)
    end

    test "renders git deleted sign when no diagnostic" do
      result = Gutter.render_sign(0, 0, 5, sign_ctx(%{git_signs: %{5 => :deleted}}))
      assert_sign(result, "▁ ", @git_colors.deleted_fg)
    end

    test "diagnostic takes priority over git sign on same line" do
      result =
        Gutter.render_sign(
          0,
          0,
          5,
          sign_ctx(%{diagnostic_signs: %{5 => :error}, git_signs: %{5 => :added}})
        )

      assert_sign(result, "E ", @colors.error_fg)
    end

    test "renders gutter icon annotation when no diagnostic or git sign" do
      decorations = %Decorations{
        annotations: [
          %LineAnnotation{id: make_ref(), line: 10, text: "!", kind: :gutter_icon, fg: 0xAA55FF}
        ]
      }

      result = Gutter.render_sign(0, 0, 10, sign_ctx(%{decorations: decorations}))
      assert_sign(result, "! ", 0xAA55FF)
    end

    test "renders empty space when no diagnostic, git sign, or gutter annotation" do
      result = Gutter.render_sign(0, 0, 10, sign_ctx(%{}))
      assert_sign(result, "  ", nil)
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
