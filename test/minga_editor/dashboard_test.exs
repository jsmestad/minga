defmodule MingaEditor.DashboardTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Dashboard
  alias MingaEditor.Renderer
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.Viewport
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.Item

  describe "new_state/1" do
    test "creates state with quick actions when no recent files" do
      state = Dashboard.new_state()
      assert state.cursor == 0
      assert length(state.items) == 5
    end

    test "includes recent files as items" do
      state = Dashboard.new_state(["lib/foo.ex", "lib/bar.ex"])
      assert length(state.items) == 7
      labels = Enum.map(state.items, & &1.label)
      assert "lib/foo.ex" in labels
      assert "lib/bar.ex" in labels
    end

    test "caps recent files at 10" do
      files = for i <- 1..15, do: "file_#{i}.ex"
      state = Dashboard.new_state(files)
      # 5 quick actions + 10 recent files
      assert length(state.items) == 15
    end
  end

  describe "cursor_up/1" do
    test "moves cursor up" do
      state = %{Dashboard.new_state() | cursor: 2}
      assert Dashboard.cursor_up(state).cursor == 1
    end

    test "wraps to bottom from top" do
      state = %{Dashboard.new_state() | cursor: 0}
      result = Dashboard.cursor_up(state)
      assert result.cursor == length(state.items) - 1
    end
  end

  describe "cursor_down/1" do
    test "moves cursor down" do
      state = %{Dashboard.new_state() | cursor: 0}
      assert Dashboard.cursor_down(state).cursor == 1
    end

    test "wraps to top from bottom" do
      state = Dashboard.new_state()
      last = length(state.items) - 1
      state = %{state | cursor: last}
      assert Dashboard.cursor_down(state).cursor == 0
    end
  end

  describe "cursor movement with empty items" do
    test "cursor stays at 0 when no items" do
      state = %{cursor: 0, items: []}
      assert Dashboard.cursor_up(state).cursor == 0
      assert Dashboard.cursor_down(state).cursor == 0
    end
  end

  describe "selected_command/1" do
    test "returns command for current cursor position" do
      state = Dashboard.new_state()
      assert Dashboard.selected_command(state) == :find_file
    end

    test "returns correct command after moving cursor" do
      state = Dashboard.new_state() |> Dashboard.cursor_down()
      assert Dashboard.selected_command(state) == :project_recent_files
    end

    test "returns open_file command for recent file items" do
      state = Dashboard.new_state(["lib/foo.ex"])
      # Move past the 5 quick actions to the first recent file
      state = Enum.reduce(1..5, state, fn _, s -> Dashboard.cursor_down(s) end)
      assert Dashboard.selected_command(state) == {:open_file, "lib/foo.ex"}
    end

    test "returns nil for empty items" do
      state = %{cursor: 0, items: []}
      assert Dashboard.selected_command(state) == nil
    end
  end

  describe "render/4" do
    test "returns a list of draw tuples" do
      theme = MingaEditor.UI.Theme.get!(:doom_one)
      state = Dashboard.new_state()
      draws = Dashboard.render(80, 24, theme, state)
      assert is_list(draws)
      assert draws != []
    end

    test "all draws are valid tuples" do
      theme = MingaEditor.UI.Theme.get!(:doom_one)
      state = Dashboard.new_state()
      draws = Dashboard.render(80, 24, theme, state)
      assert draws != []

      Enum.each(draws, fn {row, col, text, _style} ->
        assert is_integer(row) and row >= 0
        assert is_integer(col) and col >= 0
        assert is_binary(text)
      end)
    end

    test "version string appears in draws" do
      theme = MingaEditor.UI.Theme.get!(:doom_one)
      state = Dashboard.new_state()
      draws = Dashboard.render(80, 24, theme, state)

      texts = Enum.map(draws, fn {_, _, text, _} -> text end)
      assert Enum.any?(texts, &String.contains?(&1, "Minga v"))
    end

    test "quick action labels appear in draws" do
      theme = MingaEditor.UI.Theme.get!(:doom_one)
      state = Dashboard.new_state()
      draws = Dashboard.render(80, 24, theme, state)

      texts = Enum.map(draws, fn {_, _, text, _} -> text end)
      assert Enum.any?(texts, &String.contains?(&1, "Find file"))
      assert Enum.any?(texts, &String.contains?(&1, "SPC f f"))
    end

    test "recent files appear in draws when provided" do
      theme = MingaEditor.UI.Theme.get!(:doom_one)
      state = Dashboard.new_state(["lib/my_file.ex"])
      draws = Dashboard.render(80, 24, theme, state)

      texts = Enum.map(draws, fn {_, _, text, _} -> text end)
      assert Enum.any?(texts, &String.contains?(&1, "lib/my_file.ex"))
    end

    test "renders within bounds for small terminal" do
      theme = MingaEditor.UI.Theme.get!(:doom_one)
      state = Dashboard.new_state()
      draws = Dashboard.render(40, 10, theme, state)

      Enum.each(draws, fn {row, col, _text, _style} ->
        assert row >= 0 and row < 10, "row #{row} out of bounds for height 10"
        assert col >= 0, "col #{col} is negative"
      end)
    end

    test "active item has different background" do
      theme = MingaEditor.UI.Theme.get!(:doom_one)
      dt = MingaEditor.UI.Theme.dashboard_theme(theme)
      state = Dashboard.new_state()
      draws = Dashboard.render(80, 24, theme, state)

      # The first quick action (cursor=0) should have item_active_bg
      active_bg_draws =
        Enum.filter(draws, fn {_, _, _, style} ->
          style.bg == dt.item_active_bg
        end)

      assert active_bg_draws != [], "expected active item to have highlight background"
    end
  end

  describe "dashboard renderer with picker overlay" do
    test "renders picker overlay when a picker is open with no active buffer" do
      # Build state: dashboard visible, no active buffer, picker open
      items = [%Item{id: "1", label: "file_a.ex"}, %Item{id: "2", label: "file_b.ex"}]
      picker = Picker.new(items, title: "Find File", max_visible: 10)

      state = %EditorState{
        port_manager: self(),
        workspace: %MingaEditor.Workspace.State{
          viewport: Viewport.new(24, 80),
          buffers: %Buffers{active: nil}
        },
        focus_stack: MingaEditor.Input.default_stack(),
        shell_state: %MingaEditor.Shell.Traditional.State{
          dashboard: Dashboard.new_state(),
          picker_ui: %PickerState{picker: picker, source: MingaEditor.UI.Picker.FileSource}
        },
        theme: MingaEditor.UI.Theme.get!(:doom_one)
      }

      # Render returns state; side effect is a GenServer.cast to port_manager
      _new_state = Renderer.render(state)

      # Receive the cast sent to self() (port_manager)
      assert_receive {:"$gen_cast", {:send_commands, commands}}

      # The commands should contain picker content ("> " is the prompt prefix)
      # encoded as binary protocol commands. Verify the list is non-empty
      # and longer than a bare dashboard render (which has no overlays).
      assert is_list(commands)
      assert commands != []

      # Re-render without the picker to compare command counts
      bare_state = MingaEditor.State.set_picker_ui(state, %PickerState{})
      _new_bare = Renderer.render(bare_state)
      assert_receive {:"$gen_cast", {:send_commands, bare_commands}}

      # With a picker, we should have more draw commands (the overlay draws)
      assert length(commands) > length(bare_commands),
             "picker overlay should add draw commands to the dashboard frame"
    end
  end
end
