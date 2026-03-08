defmodule Minga.Editor.PickerUITest do
  @moduledoc "Tests PickerUI.render with focused RenderInput (no EditorState needed)."

  use ExUnit.Case, async: true

  alias Minga.Editor.PickerUI
  alias Minga.Editor.PickerUI.RenderInput
  alias Minga.Editor.State.Picker, as: PickerState
  alias Minga.Editor.Viewport
  alias Minga.Picker
  alias Minga.Theme

  defp theme_picker do
    Theme.get!(:doom_one).picker
  end

  describe "render/1 with RenderInput" do
    test "returns empty draws when picker is nil" do
      input = %RenderInput{
        picker_state: %PickerState{},
        theme_picker: theme_picker(),
        viewport: Viewport.new(24, 80)
      }

      {draws, cursor} = PickerUI.render(input)
      assert draws == []
      assert cursor == nil
    end

    test "returns draws and cursor when picker is active" do
      items = [{"1", "file.ex", ""}, {"2", "test.ex", ""}]
      picker = Picker.new(items, title: "Files", max_visible: 10)

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil},
        theme_picker: theme_picker(),
        viewport: Viewport.new(24, 80)
      }

      {draws, cursor} = PickerUI.render(input)
      assert [_ | _] = draws
      assert {row, col} = cursor
      assert is_integer(row)
      assert is_integer(col)
    end

    test "cursor is on the prompt row (last row)" do
      items = [{"1", "main.ex", ""}]
      picker = Picker.new(items, title: "Files", max_visible: 5)

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil},
        theme_picker: theme_picker(),
        viewport: Viewport.new(24, 80)
      }

      {_draws, {cursor_row, _col}} = PickerUI.render(input)
      # Prompt is on the last row of the viewport
      assert cursor_row == 23
    end

    test "draw tuples have valid 4-element structure" do
      items = [{"1", "alpha.ex", "lib/"}, {"2", "beta.ex", "test/"}]
      picker = Picker.new(items, title: "Test", max_visible: 10)

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil},
        theme_picker: theme_picker(),
        viewport: Viewport.new(30, 100)
      }

      {draws, _cursor} = PickerUI.render(input)

      Enum.each(draws, fn draw ->
        assert tuple_size(draw) == 4
        {row, col, text, style} = draw
        assert is_integer(row)
        assert is_integer(col)
        assert is_binary(text)
        assert is_list(style)
      end)
    end
  end
end
