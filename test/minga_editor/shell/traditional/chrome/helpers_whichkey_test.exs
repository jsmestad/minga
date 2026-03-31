defmodule MingaEditor.Shell.Traditional.Chrome.HelpersWhichKeyTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Shell.Traditional.Chrome.Helpers, as: ChromeHelpers
  alias MingaEditor.Viewport
  alias Minga.Keymap.Bindings
  alias MingaEditor.UI.Theme

  defp build_state do
    root =
      Bindings.new()
      |> Bindings.bind([{?f, 0}], :find_file, "find file")
      |> Bindings.bind([{?b, 0}], :buffers, "buffers")
      |> Bindings.bind([{?q, 0}], :quit, "quit")

    theme = Theme.get!(:doom_one)

    %{
      shell_state: %{whichkey: %{show: true, node: root}},
      theme: theme
    }
  end

  defp viewport, do: Viewport.new(24, 80)

  describe "render_whichkey/3 bottom layout" do
    test "returns draw commands when whichkey is visible" do
      draws = ChromeHelpers.render_whichkey(build_state(), viewport(), :bottom)
      assert [_ | _] = draws
    end

    test "draws are near the bottom of the viewport" do
      draws = ChromeHelpers.render_whichkey(build_state(), viewport(), :bottom)

      rows = Enum.map(draws, fn {row, _, _, _} -> row end)
      max_row = Enum.max(rows)

      assert max_row >= 20, "bottom layout draws should be near viewport bottom"
    end

    test "returns empty when whichkey is not visible" do
      state = %{shell_state: %{whichkey: %{show: false, node: nil}}, theme: Theme.get!(:doom_one)}
      assert [] = ChromeHelpers.render_whichkey(state, viewport(), :bottom)
    end
  end

  describe "render_whichkey/3 float layout" do
    test "returns draw commands when whichkey is visible" do
      draws = ChromeHelpers.render_whichkey(build_state(), viewport(), :float)
      assert [_ | _] = draws
    end

    test "draws include rounded border characters" do
      draws = ChromeHelpers.render_whichkey(build_state(), viewport(), :float)
      texts = Enum.map(draws, fn {_, _, text, _} -> text end)

      assert Enum.any?(texts, &String.contains?(&1, "╭")),
             "expected rounded top-left border in float layout"
    end

    test "draws include 'Which Key' title" do
      draws = ChromeHelpers.render_whichkey(build_state(), viewport(), :float)
      texts = Enum.map(draws, fn {_, _, text, _} -> text end)

      assert Enum.any?(texts, &String.contains?(&1, "Which Key")),
             "expected 'Which Key' title in float layout"
    end

    test "draws are centered (not anchored to bottom)" do
      draws = ChromeHelpers.render_whichkey(build_state(), viewport(), :float)

      rows = Enum.map(draws, fn {row, _, _, _} -> row end)
      min_row = Enum.min(rows)

      assert min_row > 0, "float layout should not start at row 0"
      assert min_row < 20, "float layout should be centered, not at the very bottom"
    end

    test "draws contain the binding keys" do
      draws = ChromeHelpers.render_whichkey(build_state(), viewport(), :float)
      all_text = Enum.map_join(draws, fn {_, _, text, _} -> text end)

      assert String.contains?(all_text, "f"), "expected 'f' binding in draws"
      assert String.contains?(all_text, "b"), "expected 'b' binding in draws"
      assert String.contains?(all_text, "q"), "expected 'q' binding in draws"
    end
  end
end
