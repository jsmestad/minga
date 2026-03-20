defmodule Minga.Port.ProtocolSchemaTest do
  @moduledoc """
  Validates that Elixir opcode constants match the canonical
  protocol_schema.json. Catches drift between the schema and
  the Elixir protocol implementation.
  """

  use ExUnit.Case, async: true

  @schema_path Path.join([File.cwd!(), "docs", "protocol_schema.json"])

  setup_all do
    schema = @schema_path |> File.read!() |> Jason.decode!()
    %{schema: schema}
  end

  describe "render opcodes match schema" do
    test "all render opcode hex values match", %{schema: schema} do
      expected = schema["opcodes"]["render"]

      assert_opcode(expected, "draw_text", 0x10)
      assert_opcode(expected, "set_cursor", 0x11)
      assert_opcode(expected, "clear", 0x12)
      assert_opcode(expected, "batch_end", 0x13)
      assert_opcode(expected, "define_region", 0x14)
      assert_opcode(expected, "set_cursor_shape", 0x15)
      assert_opcode(expected, "set_title", 0x16)
      assert_opcode(expected, "set_window_bg", 0x17)
      assert_opcode(expected, "clear_region", 0x18)
      assert_opcode(expected, "destroy_region", 0x19)
      assert_opcode(expected, "set_active_region", 0x1A)
      assert_opcode(expected, "draw_styled_text", 0x1C)
    end
  end

  describe "GUI chrome opcodes match schema" do
    test "all GUI chrome opcode hex values match", %{schema: schema} do
      expected = schema["opcodes"]["gui_chrome"]

      assert_opcode(expected, "gui_file_tree", 0x70)
      assert_opcode(expected, "gui_tab_bar", 0x71)
      assert_opcode(expected, "gui_which_key", 0x72)
      assert_opcode(expected, "gui_completion", 0x73)
      assert_opcode(expected, "gui_theme", 0x74)
      assert_opcode(expected, "gui_breadcrumb", 0x75)
      assert_opcode(expected, "gui_status_bar", 0x76)
      assert_opcode(expected, "gui_picker", 0x77)
      assert_opcode(expected, "gui_agent_chat", 0x78)
      assert_opcode(expected, "gui_gutter_sep", 0x79)
      assert_opcode(expected, "gui_cursorline", 0x7A)
      assert_opcode(expected, "gui_gutter", 0x7B)
      assert_opcode(expected, "gui_bottom_panel", 0x7C)
      assert_opcode(expected, "gui_picker_preview", 0x7D)
      assert_opcode(expected, "gui_tool_manager", 0x7E)
    end
  end

  describe "input opcodes match schema" do
    test "all input opcode hex values match", %{schema: schema} do
      expected = schema["opcodes"]["input"]

      assert_opcode(expected, "key_press", 0x01)
      assert_opcode(expected, "resize", 0x02)
      assert_opcode(expected, "ready", 0x03)
      assert_opcode(expected, "mouse_event", 0x04)
      assert_opcode(expected, "paste_event", 0x06)
      assert_opcode(expected, "gui_action", 0x07)
      assert_opcode(expected, "log_message", 0x60)
    end
  end

  describe "gui_action sub-opcodes match schema" do
    test "all gui_action sub-opcode hex values match", %{schema: schema} do
      expected = schema["gui_actions"]

      assert_opcode(expected, "select_tab", 0x01)
      assert_opcode(expected, "close_tab", 0x02)
      assert_opcode(expected, "file_tree_click", 0x03)
      assert_opcode(expected, "file_tree_toggle", 0x04)
      assert_opcode(expected, "completion_select", 0x05)
      assert_opcode(expected, "breadcrumb_click", 0x06)
      assert_opcode(expected, "toggle_panel", 0x07)
      assert_opcode(expected, "new_tab", 0x08)
      assert_opcode(expected, "panel_switch_tab", 0x09)
      assert_opcode(expected, "panel_dismiss", 0x0A)
      assert_opcode(expected, "panel_resize", 0x0B)
      assert_opcode(expected, "open_file", 0x0C)
      assert_opcode(expected, "file_tree_new_file", 0x0D)
      assert_opcode(expected, "file_tree_new_folder", 0x0E)
      assert_opcode(expected, "file_tree_collapse_all", 0x0F)
      assert_opcode(expected, "file_tree_refresh", 0x10)
      assert_opcode(expected, "tool_install", 0x11)
      assert_opcode(expected, "tool_uninstall", 0x12)
      assert_opcode(expected, "tool_update", 0x13)
      assert_opcode(expected, "tool_dismiss", 0x14)
    end
  end

  describe "gui_window_content opcode matches schema" do
    test "gui_window_content hex value matches", %{schema: schema} do
      expected = schema["opcodes"]["gui_semantic"]
      assert_opcode(expected, "gui_window_content", 0x80)
    end
  end

  # Helper: asserts an opcode name maps to the expected hex value in the schema
  defp assert_opcode(section, name, expected_value) do
    entry = section[name]
    assert entry != nil, "Schema missing opcode: #{name}"
    hex_str = entry["hex"]

    # Strip "0x" prefix and parse as hex
    trimmed = String.replace_prefix(hex_str, "0x", "")
    {schema_value, ""} = Integer.parse(trimmed, 16)

    assert schema_value == expected_value,
           "Opcode #{name}: schema says #{hex_str} (#{schema_value}), " <>
             "Elixir says 0x#{Integer.to_string(expected_value, 16)}"
  end
end
