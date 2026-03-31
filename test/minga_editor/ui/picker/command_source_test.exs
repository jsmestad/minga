defmodule MingaEditor.UI.Picker.CommandSourceTest do
  use ExUnit.Case, async: true

  alias MingaEditor.UI.Picker.Item

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Command
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.UI.Picker.CommandSource

  describe "on_select/2 — regular command" do
    test "sets pending_command for non-scopeable commands" do
      state = %{pending_command: nil}

      result =
        CommandSource.on_select(
          %Item{id: :save, label: "save: Save the current file", description: ""},
          state
        )

      assert result.pending_command == :save
    end
  end

  describe "on_select/2 — scopeable command" do
    test "opens scope picker instead of setting pending_command" do
      {:ok, buf} = BufferServer.start_link(content: "hello")

      state = %EditorState{
        port_manager: nil,
        workspace: %MingaEditor.Workspace.State{
          viewport: Viewport.new(24, 80),
          buffers: %Buffers{active: buf, list: [buf], active_index: 0},
          editing: VimState.new()
        },
        shell_state: %MingaEditor.Shell.Traditional.State{picker_ui: %PickerState{}}
      }

      result =
        CommandSource.on_select(
          %Item{id: :toggle_wrap, label: "toggle_wrap: Toggle word wrap", description: ""},
          state
        )

      # Should have opened the scope picker, not set pending_command
      assert is_nil(Map.get(result, :pending_command))
      # The scope picker should be open
      assert result.shell_state.picker_ui.picker != nil
      assert result.shell_state.picker_ui.source == MingaEditor.UI.Picker.OptionScopeSource
      # Context should carry the option info
      assert result.shell_state.picker_ui.context.option_name == :wrap
      assert is_boolean(result.shell_state.picker_ui.context.new_value)
    end
  end

  describe "Command.scopeable?/1" do
    test "returns true for commands with a scope descriptor" do
      cmd = %Command{
        name: :toggle_wrap,
        description: "Toggle wrap",
        execute: & &1,
        option_toggle: :wrap
      }

      assert Command.scopeable?(cmd)
    end

    test "returns false for commands without a scope" do
      cmd = %Command{name: :save, description: "Save", execute: & &1}
      refute Command.scopeable?(cmd)
    end
  end

  describe "Command.compute_new_value/2" do
    test "boolean toggle negates the value" do
      cmd = %Command{
        name: :test,
        description: "Test",
        execute: & &1,
        option_toggle: :wrap
      }

      assert Command.compute_new_value(cmd, true) == false
      assert Command.compute_new_value(cmd, false) == true
    end

    test "function toggle calls the function" do
      cycle = fn
        :a -> :b
        :b -> :c
        :c -> :a
      end

      cmd = %Command{
        name: :test,
        description: "Test",
        execute: & &1,
        option_toggle: {:mode, cycle}
      }

      assert Command.compute_new_value(cmd, :a) == :b
      assert Command.compute_new_value(cmd, :c) == :a
    end
  end
end
