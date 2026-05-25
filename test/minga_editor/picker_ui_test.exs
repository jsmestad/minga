defmodule MingaEditor.PickerUITest do
  @moduledoc "Tests PickerUI rendering and picker-state transitions."

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.PickerUI
  alias MingaEditor.PickerUI.RenderInput
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.ModalOverlay
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

  defp marked_buffer_picker do
    [
      %Item{id: 0, label: "alpha"},
      %Item{id: 1, label: "beta"},
      %Item{id: 2, label: "gamma"}
    ]
    |> Picker.new(title: "Switch buffer", max_visible: 10)
    |> Picker.move_down()
    |> Picker.toggle_mark()
    |> Picker.move_down()
    |> Picker.toggle_mark()
  end

  defp picker_state_with_buffers([first_content | rest]) do
    state = TestHelpers.base_state(content: first_content)

    buffers =
      Enum.reduce(rest, state.workspace.buffers, fn content, acc ->
        {:ok, pid} = BufferProcess.start_link(content: content)
        Buffers.add_background(acc, pid)
      end)

    picker_state = %PickerState{
      picker: marked_buffer_picker(),
      source: MingaEditor.UI.Picker.BufferSource,
      restore: 0
    }

    state
    |> EditorState.set_buffers(buffers)
    |> ModalOverlay.open(:picker, PickerPayload.new(picker_state))
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

  defmodule NoBulkActionsSource do
    @behaviour MingaEditor.UI.Picker.Source

    alias MingaEditor.UI.Picker.Item

    @impl true
    def title, do: "No bulk actions"

    @impl true
    def candidates(_ctx), do: []

    @impl true
    def on_select(%Item{id: id}, state), do: Map.put(state, :selected_item_id, id)

    @impl true
    def on_cancel(state), do: state

    @impl true
    def actions(_item), do: [{"Open", :open}, {"Delete", :delete}]

    @impl true
    def on_action(:open, %Item{id: id}, state), do: Map.put(state, :action_item_id, id)

    def on_action(:delete, %Item{id: id}, state),
      do: Map.put(state, :action_item_id, {:delete, id})

    def on_action(_action, _item, state), do: state
  end

  defp picker_state_for_source(state, source, items) do
    picker = items |> Picker.new(title: "Test", max_visible: 10) |> mark_all_picker()

    picker_state = %PickerState{
      picker: picker,
      source: source,
      restore: state.workspace.buffers.active_index
    }

    ModalOverlay.open(state, :picker, PickerPayload.new(picker_state))
  end

  defp mark_all_picker(%Picker{items: []} = picker), do: picker

  defp mark_all_picker(%Picker{} = picker) do
    Enum.reduce(1..length(picker.items), picker, fn _, acc ->
      Picker.toggle_mark(acc) |> Picker.move_down()
    end)
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

    test "default mode prompt keeps the plain greater-than prefix" do
      picker =
        [%Item{id: "1", label: "main.ex"}]
        |> Picker.new(title: "Files", max_visible: 5)
        |> Picker.filter("main")

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil},
        theme_picker: theme_picker(),
        viewport: Viewport.new(24, 80)
      }

      {draws, {_cursor_row, cursor_col}} = PickerUI.render(input)

      assert cursor_col == String.length("> main")

      assert Enum.any?(draws, fn
               {23, 0, "> main" <> _padding, _face} -> true
               _ -> false
             end)

      refute Enum.any?(draws, fn
               {23, 0, "[" <> _indicator, _face} -> true
               _ -> false
             end)
    end

    test "switched mode prompt renders a styled mode badge" do
      picker =
        [%Item{id: "1", label: "main.ex"}]
        |> Picker.new(title: "Files", max_visible: 5)
        |> Picker.filter("main")

      theme = theme_picker()

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil, mode_prefix: ">"},
        theme_picker: theme,
        viewport: Viewport.new(24, 80)
      }

      {draws, {_cursor_row, cursor_col}} = PickerUI.render(input)

      assert cursor_col == String.length("[>] main")

      assert Enum.any?(draws, fn
               {23, 0, "[>] main" <> _padding, face} -> face.fg == theme.highlight_fg
               _ -> false
             end)

      assert Enum.any?(draws, fn
               {23, 0, "[>]", face} -> face.fg == theme.match_fg and face.bg == theme.prompt_bg
               _ -> false
             end)
    end

    test "hash mode prompt renders the same styled badge" do
      picker =
        [%Item{id: "1", label: "main.ex"}]
        |> Picker.new(title: "Files", max_visible: 5)
        |> Picker.filter("main")

      theme = theme_picker()

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil, mode_prefix: "#"},
        theme_picker: theme,
        viewport: Viewport.new(24, 80)
      }

      {draws, {_cursor_row, cursor_col}} = PickerUI.render(input)

      assert cursor_col == String.length("[#] main")

      assert Enum.any?(draws, fn
               {23, 0, "[#] main" <> _padding, face} -> face.fg == theme.highlight_fg
               _ -> false
             end)

      assert Enum.any?(draws, fn
               {23, 0, "[#]", face} -> face.fg == theme.match_fg and face.bg == theme.prompt_bg
               _ -> false
             end)
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

    test "bottom separator shows marked count" do
      picker =
        [
          %Item{id: :one, label: "one.ex"},
          %Item{id: :two, label: "two.ex"},
          %Item{id: :three, label: "three.ex"}
        ]
        |> Picker.new(title: "Files", max_visible: 10)
        |> Picker.toggle_mark()
        |> Picker.move_down()
        |> Picker.toggle_mark()

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil},
        theme_picker: theme_picker(),
        viewport: Viewport.new(12, 90)
      }

      {draws, _cursor} = PickerUI.render(input)

      assert Enum.any?(draws, fn {_row, _col, text, _face} ->
               String.contains?(text, "3/3 (2 marked)")
             end)
    end

    test "bottom picker shows 'No matches' when query filters all items" do
      items = [%Item{id: "1", label: "alpha.ex"}, %Item{id: "2", label: "beta.ex"}]
      picker = items |> Picker.new(title: "Files", max_visible: 10) |> Picker.filter("zzzzz")

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil},
        theme_picker: theme_picker(),
        viewport: Viewport.new(24, 80)
      }

      {draws, _cursor} = PickerUI.render(input)

      assert Enum.any?(draws, fn {_row, _col, text, _face} ->
               String.contains?(text, "No matches")
             end)
    end

    test "bottom picker does not show 'No matches' with an empty query" do
      items = [%Item{id: "1", label: "alpha.ex"}]
      picker = Picker.new(items, title: "Files", max_visible: 10)

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil},
        theme_picker: theme_picker(),
        viewport: Viewport.new(24, 80)
      }

      {draws, _cursor} = PickerUI.render(input)

      refute Enum.any?(draws, fn {_row, _col, text, _face} ->
               String.contains?(text, "No matches")
             end)
    end

    test "centered picker shows 'No matches' when query filters all items" do
      items = [%Item{id: "1", label: "alpha.ex"}, %Item{id: "2", label: "beta.ex"}]
      picker = items |> Picker.new(title: "Files", max_visible: 10) |> Picker.filter("zzzzz")

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil, layout: :centered},
        theme_picker: theme_picker(),
        viewport: Viewport.new(24, 80)
      }

      {draws, _cursor} = PickerUI.render(input)

      assert Enum.any?(draws, fn {_row, _col, text, _face} ->
               String.contains?(text, "No matches")
             end)
    end

    test "'No matches' disappears when query is backspaced to a matching state" do
      items = [%Item{id: "1", label: "alpha.ex"}, %Item{id: "2", label: "beta.ex"}]

      picker =
        items
        |> Picker.new(title: "Files", max_visible: 10)
        |> Picker.filter("zzzzz")
        |> Picker.backspace()
        |> Picker.backspace()
        |> Picker.backspace()
        |> Picker.backspace()
        |> Picker.backspace()

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil},
        theme_picker: theme_picker(),
        viewport: Viewport.new(24, 80)
      }

      {draws, _cursor} = PickerUI.render(input)

      refute Enum.any?(draws, fn {_row, _col, text, _face} ->
               String.contains?(text, "No matches")
             end)
    end
  end

  describe "loading and error state rendering" do
    test "bottom picker shows 'Searching...' when load_status is :loading" do
      picker = Picker.new([], title: "Workspace Symbols", max_visible: 10)

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil, load_status: :loading},
        theme_picker: theme_picker(),
        viewport: Viewport.new(24, 80)
      }

      {draws, _cursor} = PickerUI.render(input)

      assert Enum.any?(draws, fn {_row, _col, text, _face} ->
               String.contains?(text, "Searching...")
             end)
    end

    test "centered picker shows 'Searching...' when load_status is :loading" do
      picker = Picker.new([], title: "Workspace Symbols", max_visible: 10)

      input = %RenderInput{
        picker_state: %PickerState{
          picker: picker,
          source: nil,
          layout: :centered,
          load_status: :loading
        },
        theme_picker: theme_picker(),
        viewport: Viewport.new(24, 80)
      }

      {draws, _cursor} = PickerUI.render(input)

      assert Enum.any?(draws, fn {_row, _col, text, _face} ->
               String.contains?(text, "Searching...")
             end)
    end

    test "bottom picker shows error message when load_status is {:error, reason}" do
      picker = Picker.new([], title: "Workspace Symbols", max_visible: 10)

      input = %RenderInput{
        picker_state: %PickerState{
          picker: picker,
          source: nil,
          load_status: {:error, "Source timed out"}
        },
        theme_picker: theme_picker(),
        viewport: Viewport.new(24, 80)
      }

      {draws, _cursor} = PickerUI.render(input)

      assert Enum.any?(draws, fn {_row, _col, text, _face} ->
               String.contains?(text, "Source timed out")
             end)
    end

    test "centered picker shows error message when load_status is {:error, reason}" do
      picker = Picker.new([], title: "Workspace Symbols", max_visible: 10)

      input = %RenderInput{
        picker_state: %PickerState{
          picker: picker,
          source: nil,
          layout: :centered,
          load_status: {:error, "LSP not available"}
        },
        theme_picker: theme_picker(),
        viewport: Viewport.new(24, 80)
      }

      {draws, _cursor} = PickerUI.render(input)

      assert Enum.any?(draws, fn {_row, _col, text, _face} ->
               String.contains?(text, "LSP not available")
             end)
    end

    test "loading state takes priority over 'No matches' even with non-empty query" do
      picker = Picker.new([], title: "Symbols", max_visible: 10) |> Picker.filter("foo")

      input = %RenderInput{
        picker_state: %PickerState{picker: picker, source: nil, load_status: :loading},
        theme_picker: theme_picker(),
        viewport: Viewport.new(24, 80)
      }

      {draws, _cursor} = PickerUI.render(input)

      assert Enum.any?(draws, fn {_row, _col, text, _face} ->
               String.contains?(text, "Searching...")
             end)

      refute Enum.any?(draws, fn {_row, _col, text, _face} ->
               String.contains?(text, "No matches")
             end)
    end
  end

  describe "bulk picker actions" do
    test "C-o shows source bulk actions when items are marked" do
      state = picker_state_with_buffers(["alpha", "beta", "gamma"])

      new_state = PickerUI.handle_key(state, ?o, MingaEditor.Input.mod_ctrl())
      {:picker, %{picker_ui: %{action_menu: {actions, 0}}}} = new_state.shell_state.modal

      assert actions == [
               {"Kill all marked",
                {:bulk, :kill_marked, Picker.marked_items(marked_buffer_picker())}}
             ]
    end

    test "Enter applies source bulk select when items are marked" do
      state = picker_state_with_buffers(["alpha", "beta", "gamma"])

      new_state = PickerUI.handle_key(state, 13, 0)

      assert new_state.shell_state.modal == :none
      assert length(new_state.workspace.buffers.list) == 1
      assert Minga.Buffer.content(new_state.workspace.buffers.active) == "alpha"
    end
  end

  describe "branch delete shortcut" do
    test "plain d remains query input for a generic picker that exposes delete actions" do
      picker =
        Picker.new([%Item{id: :delete_me, label: "Delete me"}], title: "Delete Action Test")

      picker_state = %PickerState{
        picker: picker,
        source: Minga.Test.DeleteActionPickerSource,
        restore: 0
      }

      state = %EditorState{
        port_manager: nil,
        workspace: %SessionState{viewport: Viewport.new(24, 80), editing: VimState.new()},
        shell_state: %ShellState{modal: {:picker, PickerPayload.new(picker_state)}}
      }

      result = PickerUI.handle_key(state, ?d, 0)
      {:picker, %{picker_ui: picker_ui}} = result.shell_state.modal

      assert picker_ui.picker.query == "d"
      assert result.shell_state.status_msg == nil
      assert result.workspace.editing.mode == :normal
    end
  end

  describe "bulk action fallback for sources without bulk support" do
    test "Enter still performs normal single select when marks exist" do
      state = TestHelpers.base_state(content: "initial")

      picker_state =
        picker_state_for_source(state, NoBulkActionsSource, [
          %Item{id: :first, label: "first"},
          %Item{id: :second, label: "second"}
        ])

      new_state = PickerUI.handle_key(picker_state, 13, 0)

      assert new_state.shell_state.modal == :none
      assert Map.get(new_state, :selected_item_id) == :first
      refute Map.has_key?(new_state, :bulk_selected)
    end

    test "C-o falls back to normal per-item actions and Enter dispatches on_action" do
      state = TestHelpers.base_state(content: "initial")

      picker_state =
        picker_state_for_source(state, NoBulkActionsSource, [
          %Item{id: :first, label: "first"},
          %Item{id: :second, label: "second"}
        ])

      menu_state = PickerUI.handle_key(picker_state, ?o, MingaEditor.Input.mod_ctrl())

      assert {:picker, %{picker_ui: %{action_menu: {actions, 0}}}} = menu_state.shell_state.modal
      assert Enum.map(actions, &elem(&1, 0)) == ["Open", "Delete"]

      new_state = PickerUI.handle_key(menu_state, 13, 0)

      assert new_state.shell_state.modal == :none
      assert Map.get(new_state, :action_item_id) == :first
      refute Map.has_key?(new_state, :bulk_selected)
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

    test "backspace through a mode prefix restores the original source and prompt" do
      {state, _original_buf, _preview_buf} = preview_promotion_state()

      switched_state = PickerUI.handle_key(state, ?>, 0)
      {:picker, %{picker_ui: switched_pui}} = switched_state.shell_state.modal
      assert switched_pui.source == MingaEditor.UI.Picker.CommandSource
      assert switched_pui.original_source == MingaEditor.UI.Picker.FileSource
      assert switched_pui.mode_prefix == ">"

      reverted_state = PickerUI.handle_key(switched_state, 127, 0)
      {:picker, %{picker_ui: reverted_pui}} = reverted_state.shell_state.modal
      assert reverted_pui.source == MingaEditor.UI.Picker.FileSource
      assert reverted_pui.original_source == nil
      assert reverted_pui.mode_prefix == ""

      {draws, {cursor_row, cursor_col}} =
        PickerUI.render(reverted_state, reverted_state.terminal_viewport)

      assert cursor_row == reverted_state.terminal_viewport.rows - 1
      assert cursor_col == 2

      assert Enum.any?(draws, fn
               {row, 0, text, _face} when row == reverted_state.terminal_viewport.rows - 1 ->
                 String.starts_with?(text, "> ")

               _ ->
                 false
             end)

      refute Enum.any?(draws, fn
               {row, 0, text, _face} when row == reverted_state.terminal_viewport.rows - 1 ->
                 String.starts_with?(text, "[")

               _ ->
                 false
             end)
    end

    test "hash mode switches to project search and backspaces to the original source" do
      {state, _original_buf, _preview_buf} = preview_promotion_state()

      switched_state = PickerUI.handle_key(state, ?#, 0)
      {:picker, %{picker_ui: switched_pui}} = switched_state.shell_state.modal
      assert switched_pui.source == MingaEditor.UI.Picker.ProjectSearchSource
      assert switched_pui.original_source == MingaEditor.UI.Picker.FileSource
      assert switched_pui.mode_prefix == "#"

      reverted_state = PickerUI.handle_key(switched_state, 127, 0)
      {:picker, %{picker_ui: reverted_pui}} = reverted_state.shell_state.modal
      assert reverted_pui.source == MingaEditor.UI.Picker.FileSource
      assert reverted_pui.original_source == nil
      assert reverted_pui.mode_prefix == ""

      {draws, {cursor_row, cursor_col}} =
        PickerUI.render(reverted_state, reverted_state.terminal_viewport)

      assert cursor_row == reverted_state.terminal_viewport.rows - 1
      assert cursor_col == 2

      assert Enum.any?(draws, fn
               {row, 0, text, _face} when row == reverted_state.terminal_viewport.rows - 1 ->
                 String.starts_with?(text, "> ")

               _ ->
                 false
             end)

      refute Enum.any?(draws, fn
               {row, 0, text, _face} when row == reverted_state.terminal_viewport.rows - 1 ->
                 String.starts_with?(text, "[")

               _ ->
                 false
             end)
    end

    test "typing fix in git log stays in the fuzzy query" do
      {state, _original_buf, _preview_buf} = preview_promotion_state()

      source = :"Elixir.MingaEditor.PickerUITest.GitLogSource"
      picker = Picker.new([%Item{id: "abc123", label: "abc123"}], title: "Git Log")
      picker_state = %PickerState{picker: picker, source: source}
      state = put_in(state.shell_state.modal, {:picker, PickerPayload.new(picker_state)})

      state = Enum.reduce(~c"fix", state, fn cp, acc -> PickerUI.handle_key(acc, cp, 0) end)
      {:picker, %{picker_ui: pui}} = state.shell_state.modal

      assert pui.source == source
      assert pui.picker.query == "fix"
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

    test "centered switched mode prompt renders a styled mode badge" do
      picker =
        [%Item{id: "1", label: "item"}]
        |> Picker.new(title: "Test", max_visible: 5)
        |> Picker.filter("item")

      theme = theme_picker()

      input = %RenderInput{
        picker_state: %PickerState{
          picker: picker,
          source: nil,
          layout: :centered,
          mode_prefix: "@"
        },
        theme_picker: theme,
        viewport: Viewport.new(24, 80)
      }

      {draws, {_cursor_row, cursor_col}} = PickerUI.render(input)

      assert cursor_col > String.length("[@] item")

      assert Enum.any?(draws, fn
               {_row, _col, "[@] item" <> _padding, face} -> face.fg == theme.highlight_fg
               _ -> false
             end)

      assert Enum.any?(draws, fn
               {_row, _col, "[@]", face} ->
                 face.fg == theme.match_fg and face.bg == theme.prompt_bg

               _ ->
                 false
             end)
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
