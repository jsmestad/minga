defmodule MingaEditor.DashboardTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Dashboard
  alias MingaEditor.Renderer
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
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

  describe "dashboard renderer with picker overlay" do
    test "renders picker overlay when a picker is open with no active buffer" do
      # Build state: dashboard visible, no active buffer, picker open
      items = [%Item{id: "1", label: "file_a.ex"}, %Item{id: "2", label: "file_b.ex"}]
      picker = Picker.new(items, title: "Find File", max_visible: 10)

      state = %EditorState{
        port_manager: self(),
        workspace: %MingaEditor.Session.State{
          viewport: Viewport.new(24, 80),
          buffers: %Buffers{active: nil}
        },
        focus_stack: MingaEditor.Input.default_stack(),
        shell_state: %MingaEditor.Shell.Traditional.State{
          modal:
            {:picker,
             PickerPayload.new(%PickerState{
               picker: picker,
               source: MingaEditor.UI.Picker.FileSource
             })}
        },
        theme: MingaEditor.UI.Theme.get!(:doom_one)
      }

      # Render returns state; side effect is a GenServer.cast to port_manager
      _new_state = Renderer.render(state)

      # Receive the cast sent to self() (port_manager)
      assert_receive {:"$gen_cast", {:send_commands, commands}}

      # The semantic protocol always emits a single gui_picker (0x77) command;
      # its visibility is carried in the payload (a non-zero section count when
      # the picker is open). The old assertion compared command *counts*, which
      # no longer changes between open and dismissed because the picker is one
      # retained command either way. Assert the picker is emitted *visible*
      # instead.
      assert visible_picker_command?(commands),
             "expected a visible gui_picker (0x77) command while the picker is open"

      # Re-render without the picker: the gui_picker command is still present,
      # but now in its hidden (zero-section) form.
      bare_state = ModalOverlay.dismiss(state)
      _new_bare = Renderer.render(bare_state)
      assert_receive {:"$gen_cast", {:send_commands, bare_commands}}

      refute visible_picker_command?(bare_commands),
             "expected the gui_picker command to be hidden after the picker is dismissed"
    end
  end

  # The gui_picker (0x77) command's second byte is its section count: 0 means
  # the picker is hidden, non-zero means it carries visible picker content.
  @gui_picker_opcode 0x77
  defp visible_picker_command?(commands) do
    Enum.any?(commands, fn
      <<@gui_picker_opcode, section_count, _rest::binary>> -> section_count > 0
      _ -> false
    end)
  end
end
