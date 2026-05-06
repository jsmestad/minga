defmodule MingaEditor.PickerUITest do
  @moduledoc "Tests PickerUI rendering and picker-state transitions."

  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
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
  alias MingaEditor.Workspace.State, as: WorkspaceState

  defp theme_picker do
    Theme.get!(:doom_one).picker
  end

  defp preview_promotion_state do
    {:ok, original_buf} = BufferServer.start_link(content: "original")
    {:ok, preview_buf} = BufferServer.start_link(content: "preview")
    win_id = 1
    original_window = Window.new(win_id, original_buf, 24, 80)
    preview_window = %{original_window | buffer: preview_buf, content: {:buffer, preview_buf}}

    original_workspace = %WorkspaceState{
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
    tb = TabBar.update_context(tb, 1, WorkspaceState.to_tab_context(original_workspace))

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

    test "all draws are within the floating window rect" do
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

      # FloatingWindow at 60% x 70% centered in 80x24
      box_w = div(80 * 60, 100)
      box_h = div(24 * 70, 100)
      box_row = div(24 - box_h, 2)
      box_col = div(80 - box_w, 2)

      Enum.each(draws, fn {row, col, _text, _style} ->
        assert row >= box_row and row < box_row + box_h,
               "draw row #{row} outside box (#{box_row}..#{box_row + box_h - 1})"

        assert col >= box_col and col < box_col + box_w,
               "draw col #{col} outside box (#{box_col}..#{box_col + box_w - 1})"
      end)
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
      # It should be inside the float box
      box_h = div(24 * 70, 100)
      box_row = div(24 - box_h, 2)

      assert cursor_row >= box_row and cursor_row < box_row + box_h,
             "cursor row #{cursor_row} should be inside the float box"
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
