defmodule Minga.Picker.CommandSourceTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Command
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Picker, as: PickerState
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Picker.CommandSource

  describe "on_select/2 — regular command" do
    test "sets pending_command for non-scopeable commands" do
      state = %{pending_command: nil}
      result = CommandSource.on_select({:save, "save: Save the current file", ""}, state)
      assert result.pending_command == :save
    end
  end

  describe "on_select/2 — scopeable command" do
    test "opens scope picker instead of setting pending_command" do
      {:ok, buf} = BufferServer.start_link(content: "hello")

      state = %EditorState{
        port_manager: nil,
        viewport: %Viewport{rows: 24, cols: 80, top: 0, left: 0},
        buffers: %Buffers{active: buf, list: [buf], active_index: 0},
        picker_ui: %PickerState{},
        vim: VimState.new()
      }

      result =
        CommandSource.on_select(
          {:toggle_wrap, "toggle_wrap: Toggle word wrap", ""},
          state
        )

      # Should have opened the scope picker, not set pending_command
      assert is_nil(Map.get(result, :pending_command))
      # The scope picker should be open
      assert result.picker_ui.picker != nil
      assert result.picker_ui.source == Minga.Picker.OptionScopeSource
      # Context should carry the option info
      assert result.picker_ui.context.option_name == :wrap
      assert is_boolean(result.picker_ui.context.new_value)
    end
  end

  describe "Command.scopeable?/1" do
    test "returns true for commands with a scope descriptor" do
      cmd = %Command{
        name: :toggle_wrap,
        description: "Toggle wrap",
        execute: & &1,
        scope: %{option: :wrap, toggle: true}
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
        scope: %{option: :wrap, toggle: true}
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
        scope: %{option: :mode, toggle: cycle}
      }

      assert Command.compute_new_value(cmd, :a) == :b
      assert Command.compute_new_value(cmd, :c) == :a
    end
  end
end
