defmodule MingaEditor.Renderer.GutterTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Renderer.Gutter

  describe "geometry helpers" do
    test "total_width/1 includes sign, fold, and line-number columns" do
      assert Gutter.total_width(4) == 7
    end

    test "total_width/1 reserves sign and fold columns when line numbers are disabled" do
      assert Gutter.total_width(0) == 3
    end

    test "sign_column_width/0 returns the reserved sign column width" do
      assert Gutter.sign_column_width() == 2
    end

    test "fold_column_width/0 returns the reserved fold column width" do
      assert Gutter.fold_column_width() == 1
    end

    test "fold_column_offset/0 starts after the sign column" do
      assert Gutter.fold_column_offset() == 2
    end
  end
end
