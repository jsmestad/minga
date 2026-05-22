defmodule MingaEditor.PickerUITest do
  @moduledoc "Tests PickerUI rendering and picker-state transitions."

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.PickerUI
  alias MingaEditor.PickerUI.RenderInput
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Theme
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias MingaEditor.Session.State, as: SessionState

  defp theme_picker do
    Theme.get!(:doom_one).picker
  end

  defp preview_promotion_state do
    {:ok, original_buf} = BufferProcess.start_link(content: "original")
    {:ok, preview_buf} = BufferProcess.start_link(content: "preview")
    win_id = 1
    original_window = Window.new(win_id, original_buf, 24, 80)
    preview_window = %{original_window | buffer: preview_buf, content: {:buffer, preview_buf}}

    original_workspace = %SessionState{
      viewport: Viewport.new(24, 80),
      editing: VimState.new(),
      buffers: %Buffers{active: original_buf, list: [original_buf], active_index: 0},
      windows: %Windows{
        tree: WindowTree.new(win_id),
        map: %{win_id => original_window},
        active: win_id,
        next_id: win_id + 1
      }
    }

    preview_workspace = %{
      original_workspace
      | buffers: %Buffers{active: preview_buf, list: [original_buf, preview_buf], active_index: 1},
        windows: %{original_workspace.windows | map: %{win_id => preview_window}}
    }

    tab = Tab.new_file(1, "original.ex")
    tb = TabBar.new(tab)
    tb = TabBar.update_context(tb, 1, SessionState.to_tab_context(original_workspace))

    picker = Picker.new([%Item{id: "preview", label: "preview.ex"}], title: "Files")

    picker_state = %PickerState{
      picker: picker,
      source: MingaEditor.UI.Picker.FileSource,
      restore: 0
    }

    state = %EditorState{
      port_manager: self(),
      workspace: preview_workspace,
      shell_state: %ShellState{tab_bar: tb, modal: {:picker, PickerPayload.new(picker_state)}}
    }

    {state, original_buf, preview_buf}
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
      items = [%Item{id: "1", label: "file.ex"}, %Item{id: "2", label: "test.ex"}]
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
      items = [%Item{id: "1", label: "main.ex"}]
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

    test "bottom picker keeps the selected item visible when viewport-capped" do
      items =
        for n <- 1..40 do
          %Item{id: Integer.to_string(n), label: "file-#{n}"}
        end

      picker =
        items
        |> Picker.new(title: "Files", max_visible: 40)
        |> then(fn picker ->
          Enum.reduce(1..39, picker, fn _n, acc -> Picker.move_down(acc) end)
        end)

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil},
        theme_picker: theme_picker(),
        viewport: Viewport.new(24, 80)
      }

      {draws, _cursor} = PickerUI.render(input)
      texts = Enum.map(draws, fn {_row, _col, text, _style} -> text end)

      assert Enum.any?(texts, &String.contains?(&1, "file-40"))
      refute Enum.any?(texts, &String.contains?(&1, "file-1 "))
    end

    test "draw tuples have valid 4-element structure" do
      items = [
        %Item{id: "1", label: "alpha.ex", description: "lib/"},
        %Item{id: "2", label: "beta.ex", description: "test/"}
      ]

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
        assert %Minga.Core.Face{} = style
      end)
    end

    test "two-line items render description on an indented dim second row" do
      picker =
        Picker.new([
          %Item{id: "1", label: "file.ex", description: "lib/minga/file.ex", two_line: true}
        ])

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil},
        theme_picker: theme_picker(),
        viewport: Viewport.new(10, 80)
      }

      {draws, _cursor} = PickerUI.render(input)
      theme = theme_picker()

      assert Enum.any?(draws, fn {row, col, text, _face} ->
               row == 7 and col == 0 and String.contains?(text, "file.ex") and
                 not String.contains?(text, "lib/minga/file.ex")
             end)

      assert Enum.any?(draws, fn {row, col, text, face} ->
               row == 8 and col == 0 and String.starts_with?(text, "  lib/minga/file.ex") and
                 face.fg == theme.dim_fg and face.bg == theme.sel_bg
             end)
    end

    test "selected two-line items draw the left-edge block on both rows" do
      picker =
        Picker.new([
          %Item{id: "1", label: "file.ex", description: "lib/minga/file.ex", two_line: true}
        ])

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil},
        theme_picker: theme_picker(),
        viewport: Viewport.new(10, 80)
      }

      {draws, _cursor} = PickerUI.render(input)
      theme = theme_picker()

      assert Enum.any?(draws, fn
               {7, 0, "▌", face} -> face.fg == theme.highlight_fg and face.bg == theme.sel_bg
               _ -> false
             end)

      assert Enum.any?(draws, fn
               {8, 0, "▌", face} -> face.fg == theme.highlight_fg and face.bg == theme.sel_bg
               _ -> false
             end)
    end

    test "single-line items keep inline descriptions" do
      picker =
        Picker.new([
          %Item{id: "1", label: "file.ex", description: "lib/minga/file.ex", two_line: false}
        ])

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil},
        theme_picker: theme_picker(),
        viewport: Viewport.new(10, 80)
      }

      {draws, _cursor} = PickerUI.render(input)

      assert Enum.any?(draws, fn {_row, _col, text, _face} ->
               String.contains?(text, "file.ex") and String.contains?(text, "lib/minga/file.ex")
             end)
    end

    test "two-line viewport accounting limits visible items by consumed rows" do
      items =
        Enum.map(1..5, fn idx ->
          %Item{id: idx, label: "file#{idx}.ex", description: "lib/file#{idx}.ex", two_line: true}
        end)

      picker = Picker.new(items, title: "Files", max_visible: 10)

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil},
        theme_picker: theme_picker(),
        viewport: Viewport.new(8, 80)
      }

      {draws, _cursor} = PickerUI.render(input)
      texts = Enum.map(draws, fn {_row, _col, text, _face} -> text end)

      assert Enum.any?(texts, &String.contains?(&1, "file1.ex"))
      assert Enum.any?(texts, &String.contains?(&1, "file2.ex"))
      refute Enum.any?(texts, &String.contains?(&1, "file3.ex"))
    end

    test "tiny viewport shows the label for a two-line item instead of clipping to the description" do
      picker =
        Picker.new([
          %Item{id: "1", label: "file.ex", description: "lib/minga/file.ex", two_line: true}
        ])

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil},
        theme_picker: theme_picker(),
        viewport: Viewport.new(2, 80)
      }

      {draws, _cursor} = PickerUI.render(input)

      row_zero_text =
        draws
        |> Enum.filter(fn {row, _col, _text, _face} -> row == 0 end)
        |> Enum.map_join("", fn {_row, _col, text, _face} -> text end)

      assert String.contains?(row_zero_text, "file.ex")
      refute String.contains?(row_zero_text, "lib/minga/file.ex")
    end

    test "action menu positions by selected item row offset for two-line items" do
      picker =
        [
          %Item{id: "1", label: "one.ex", description: "lib/one.ex", two_line: true},
          %Item{id: "2", label: "two.ex", description: "lib/two.ex", two_line: true}
        ]
        |> Picker.new(title: "Files", max_visible: 10)
        |> Picker.move_down()

      input = %RenderInput{
        picker_state: %PickerState{
          picker: picker,
          source: nil,
          action_menu: {[{"Open", :open}], 0}
        },
        theme_picker: theme_picker(),
        viewport: Viewport.new(12, 90)
      }

      {draws, _cursor} = PickerUI.render(input)
      menu_col = div(90, 3)

      assert Enum.any?(draws, fn {row, col, text, _face} ->
               row == 9 and col == menu_col and String.starts_with?(text, " Actions")
             end)
    end
  end

  describe "preview promotion" do
    test "restores the original tab before creating the promoted preview tab" do
      {state, original_buf, preview_buf} = preview_promotion_state()

      new_state = PickerUI.handle_key(state, 13, 0)

      tb = new_state.shell_state.tab_bar
      assert new_state.shell_state.modal == :none
      assert TabBar.count(tb) == 2
      assert %Buffers{active: ^original_buf} = TabBar.get(tb, 1).context.buffers
      assert %Buffers{active: ^preview_buf} = TabBar.get(tb, 2).context.buffers
      assert new_state.workspace.buffers.active == preview_buf
    end
  end

  describe "render/1 centered layout" do
    test "renders draws inside a centered floating window" do
      items = [
        %Item{id: "1", label: "claude-sonnet-4", description: "Anthropic"},
        %Item{id: "2", label: "gpt-4o", description: "OpenAI"}
      ]

      picker = Picker.new(items, title: "Select Model", max_visible: 10)

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil, layout: :centered},
        theme_picker: theme_picker(),
        viewport: Viewport.new(24, 80)
      }

      {draws, cursor} = PickerUI.render(input)
      assert [_ | _] = draws
      assert {cursor_row, cursor_col} = cursor
      assert is_integer(cursor_row)
      assert is_integer(cursor_col)
    end

    test "all draws are within the auto-sized floating window rect" do
      items = [
        %Item{id: "1", label: "model-a", description: "desc"},
        %Item{id: "2", label: "model-b", description: "desc"}
      ]

      picker = Picker.new(items, title: "Models", max_visible: 10)

      vp = Viewport.new(24, 80)

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil, layout: :centered},
        theme_picker: theme_picker(),
        viewport: vp
      }

      {draws, _cursor} = PickerUI.render(input)

      # FloatingWindow stays at 60% width and sizes height to visible items + prompt + border.
      box_w = div(80 * 60, 100)
      box_h = length(items) + 3
      box_row = div(24 - box_h, 2)
      box_col = div(80 - box_w, 2)

      Enum.each(draws, fn {row, col, _text, _style} ->
        assert row >= box_row and row < box_row + box_h,
               "draw row #{row} outside box (#{box_row}..#{box_row + box_h - 1})"

        assert col >= box_col and col < box_col + box_w,
               "draw col #{col} outside box (#{box_col}..#{box_col + box_w - 1})"
      end)
    end

    test "centered picker with five items renders as a compact popup" do
      items =
        for n <- 1..5 do
          %Item{id: Integer.to_string(n), label: "model-#{n}"}
        end

      picker = Picker.new(items, title: "Models", max_visible: 10)

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil, layout: :centered},
        theme_picker: theme_picker(),
        viewport: Viewport.new(24, 80)
      }

      {draws, {cursor_row, _cursor_col}} = PickerUI.render(input)
      rows = Enum.map(draws, fn {row, _col, _text, _style} -> row end)

      box_h = length(items) + 3
      box_row = div(24 - box_h, 2)

      assert Enum.min(rows) == box_row
      assert Enum.max(rows) == box_row + box_h - 1
      assert cursor_row == box_row + box_h - 2
    end

    test "large centered picker caps height and keeps the cursor inside" do
      items =
        for n <- 1..20 do
          %Item{id: Integer.to_string(n), label: "model-#{n}"}
        end

      picker =
        items
        |> Picker.new(title: "Models", max_visible: 20)
        |> then(fn picker ->
          Enum.reduce(1..19, picker, fn _n, acc -> Picker.move_down(acc) end)
        end)

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil, layout: :centered},
        theme_picker: theme_picker(),
        viewport: Viewport.new(24, 80)
      }

      {draws, {cursor_row, _cursor_col}} = PickerUI.render(input)
      rows = Enum.map(draws, fn {row, _col, _text, _style} -> row end)
      texts = Enum.map(draws, fn {_row, _col, text, _style} -> text end)

      max_height = max(div(24 * 7, 10), 5)
      box_h = min(length(items) + 3, max_height)
      box_row = div(24 - box_h, 2)

      assert Enum.min(rows) == box_row
      assert Enum.max(rows) == box_row + box_h - 1
      assert cursor_row == box_row + box_h - 2
      assert Enum.any?(texts, &String.contains?(&1, "model-20"))
      refute Enum.any?(texts, &String.contains?(&1, "model-1 "))
    end

    test "cursor is inside the floating window (not at viewport bottom)" do
      items = [%Item{id: "1", label: "test-model"}]
      picker = Picker.new(items, title: "Pick", max_visible: 5)

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil, layout: :centered},
        theme_picker: theme_picker(),
        viewport: Viewport.new(24, 80)
      }

      {_draws, {cursor_row, _col}} = PickerUI.render(input)

      # In centered mode, cursor should NOT be at the viewport bottom (row 23)
      # It should be inside the auto-sized float box, on the prompt row.
      box_h = 1 + 3
      box_row = div(24 - box_h, 2)

      assert cursor_row == box_row + box_h - 2,
             "cursor row #{cursor_row} should be on the prompt row inside the float box"
    end

    test "contains border characters from rounded style" do
      items = [%Item{id: "1", label: "item"}]
      picker = Picker.new(items, title: "Test", max_visible: 5)

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil, layout: :centered},
        theme_picker: theme_picker(),
        viewport: Viewport.new(24, 80)
      }

      {draws, _cursor} = PickerUI.render(input)
      texts = Enum.map(draws, fn {_r, _c, text, _s} -> text end)

      assert Enum.any?(texts, &String.contains?(&1, "╭")), "expected rounded top-left border"
      assert Enum.any?(texts, &String.contains?(&1, "╰")), "expected rounded bottom-left border"
    end

    test "title appears in the draws" do
      items = [%Item{id: "1", label: "item"}]
      picker = Picker.new(items, title: "My Title", max_visible: 5)

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil, layout: :centered},
        theme_picker: theme_picker(),
        viewport: Viewport.new(24, 80)
      }

      {draws, _cursor} = PickerUI.render(input)
      texts = Enum.map(draws, fn {_r, _c, text, _s} -> text end)

      assert Enum.any?(texts, &String.contains?(&1, "My Title")),
             "expected title in centered picker draws"
    end
  end
end
