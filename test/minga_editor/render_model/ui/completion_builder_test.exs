defmodule MingaEditor.RenderModel.UI.CompletionBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Editing.Completion, as: EditingCompletion
  alias Minga.RenderModel.UI.Completion
  alias Minga.RenderModel.UI.Completion.Item
  alias MingaEditor.RenderModel.UI.CompletionBuilder
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.State.Windows

  describe "build/1" do
    test "builds hidden completion when no completion is active" do
      model = CompletionBuilder.build(ctx(nil))

      assert %Completion{} = model
      refute model.visible?
      assert model.items == []
    end

    test "builds hidden completion when filtered items are empty" do
      completion = %EditingCompletion{items: [], filtered: [], trigger_position: {0, 0}}

      model = CompletionBuilder.build(ctx(completion))

      refute model.visible?
      assert model.items == []
    end

    test "builds semantic visible completion items" do
      completion = EditingCompletion.new([item("map", :function, "Enum.map/2")], {0, 0})

      model = CompletionBuilder.build(ctx(completion, row: 7, col: 3))

      assert model.visible?
      assert model.cursor_row == 7
      assert model.cursor_col == 3
      assert model.selected_offset == 0
      assert [%Item{kind: :function, label: "map", detail: "Enum.map/2"}] = model.items
    end

    test "uses buffer cursor, viewport offset, and gutter width for popup anchor" do
      buffer = start_supervised!({Minga.Buffer.Process, content: "zero\none\nhello world"})
      assert {:ok, :absolute} = Buffer.set_option(buffer, :line_numbers, :absolute)
      :ok = Buffer.move_to(buffer, {2, 5})

      viewport = %Viewport{top: 1, left: 2, rows: 10, cols: 80, reserved: 0, visual_row_offset: 0}
      window = Window.new(1, buffer, 10, 80) |> Window.set_viewport(viewport)
      windows = %Windows{active: 1, map: %{1 => window}}
      layout = %{window_layouts: %{1 => %{content: {4, 10, 80, 10}}}}
      completion = EditingCompletion.new([item("world", :text, "word")], {2, 5})

      model = CompletionBuilder.build(%{completion: completion, windows: windows, layout: layout})

      assert model.cursor_row == 5
      assert model.cursor_col == 19
    end
  end

  defp ctx(completion, opts \\ []) do
    row = Keyword.get(opts, :row, 0)
    col = Keyword.get(opts, :col, 0)

    %{
      completion: completion,
      windows: %{active: 1, map: %{}},
      layout: %{window_layouts: %{1 => %{content: {row, col, 80, 24}}}}
    }
  end

  defp item(label, kind, detail) do
    %{
      label: label,
      kind: kind,
      insert_text: label,
      filter_text: label,
      detail: detail,
      documentation: "",
      sort_text: label,
      text_edit: nil,
      raw: nil
    }
  end
end
