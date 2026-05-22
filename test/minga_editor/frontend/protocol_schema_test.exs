defmodule MingaEditor.Frontend.ProtocolSchemaTest do
  @moduledoc """
  Validates that the canonical protocol schema covers every generated opcode category.
  """

  use ExUnit.Case, async: true

  @schema_path Path.join([File.cwd!(), "docs", "protocol_schema.toml"])

  setup_all do
    {:ok, schema} = @schema_path |> File.read!() |> Toml.decode()
    %{schema: schema}
  end

  test "every opcode entry has a name, value, category, and direction", %{schema: schema} do
    for entry <- schema["opcodes"] do
      assert is_binary(entry["name"])
      assert is_integer(entry["value"])
      assert is_binary(entry["category"])

      assert entry["direction"] in [
               "frontend_to_beam",
               "beam_to_frontend",
               "beam_to_parser",
               "parser_to_beam"
             ]
    end
  end

  test "input opcodes match schema", %{schema: schema} do
    assert_opcodes(schema, "input",
      key_press: 0x01,
      resize: 0x02,
      ready: 0x03,
      mouse_event: 0x04,
      capabilities_updated: 0x05,
      paste_event: 0x06,
      gui_action: 0x07,
      log_message: 0x60
    )
  end

  test "render opcodes match schema", %{schema: schema} do
    assert_opcodes(schema, "render",
      draw_text: 0x10,
      set_cursor: 0x11,
      clear: 0x12,
      batch_end: 0x13,
      define_region: 0x14,
      set_cursor_shape: 0x15,
      set_title: 0x16,
      set_window_bg: 0x17,
      clear_region: 0x18,
      destroy_region: 0x19,
      set_active_region: 0x1A,
      scroll_region: 0x1B,
      draw_styled_text: 0x1C
    )
  end

  test "config opcodes match schema", %{schema: schema} do
    assert_opcodes(schema, "config", set_font: 0x50, set_font_fallback: 0x51, register_font: 0x52)
  end

  test "parser command opcodes match schema", %{schema: schema} do
    assert_opcodes(schema, "parser_commands",
      set_language: 0x20,
      parse_buffer: 0x21,
      set_highlight_query: 0x22,
      load_grammar: 0x23,
      set_injection_query: 0x24,
      query_language_at: 0x25,
      edit_buffer: 0x26,
      measure_text: 0x27,
      set_fold_query: 0x28,
      set_indent_query: 0x29,
      request_indent: 0x2A,
      set_textobject_query: 0x2B,
      request_textobject: 0x2C,
      close_buffer: 0x2D,
      request_match_item: 0x2E,
      request_structural_nav: 0x2F,
      set_tags_query: 0x40
    )
  end

  test "parser response opcodes match schema", %{schema: schema} do
    assert_opcodes(schema, "parser_responses",
      highlight_spans: 0x30,
      highlight_names: 0x31,
      grammar_loaded: 0x32,
      language_at_response: 0x33,
      injection_ranges: 0x34,
      text_width: 0x35,
      fold_ranges: 0x36,
      indent_result: 0x37,
      textobject_result: 0x38,
      textobject_positions: 0x39,
      conceal_spans: 0x3A,
      request_reparse: 0x3B,
      match_item_result: 0x3C,
      node_info: 0x3D,
      document_symbols: 0x3E
    )
  end

  test "GUI chrome opcodes match schema", %{schema: schema} do
    assert_opcodes(schema, "gui_chrome",
      gui_tab_bar: 0x71,
      gui_which_key: 0x72,
      gui_completion: 0x73,
      gui_theme: 0x74,
      gui_breadcrumb: 0x75,
      gui_status_bar: 0x76,
      gui_picker: 0x77,
      gui_agent_chat: 0x78,
      gui_gutter_sep: 0x79,
      gui_cursorline: 0x7A,
      gui_gutter: 0x7B,
      gui_bottom_panel: 0x7C,
      gui_picker_preview: 0x7D,
      gui_tool_manager: 0x7E,
      gui_minibuffer: 0x7F,
      clipboard_write: 0x90,
      gui_indent_guides: 0x91,
      gui_line_spacing: 0x92,
      gui_file_tree: 0x93,
      gui_file_tree_selection: 0x94,
      gui_cursor_animation: 0x95
    )
  end

  test "GUI semantic opcodes match schema", %{schema: schema} do
    assert_opcodes(schema, "gui_semantic",
      gui_window_content: 0x80,
      gui_hover_popup: 0x81,
      gui_signature_help: 0x82,
      gui_float_popup: 0x83,
      gui_split_separators: 0x84,
      gui_git_status: 0x85,
      gui_board: 0x87,
      gui_agent_context: 0x88,
      gui_change_summary: 0x89,
      gui_hover_action: 0x96,
      gui_config_state: 0x97,
      gui_workspaces: 0x98,
      gui_notifications: 0x99
    )
  end

  test "GUI action sub-opcodes match schema", %{schema: schema} do
    assert_gui_actions(schema,
      select_tab: 0x01,
      close_tab: 0x02,
      file_tree_click: 0x03,
      file_tree_toggle: 0x04,
      completion_select: 0x05,
      breadcrumb_click: 0x06,
      toggle_panel: 0x07,
      new_tab: 0x08,
      panel_switch_tab: 0x09,
      panel_dismiss: 0x0A,
      panel_resize: 0x0B,
      open_file: 0x0C,
      file_tree_new_file: 0x0D,
      file_tree_new_folder: 0x0E,
      file_tree_collapse_all: 0x0F,
      file_tree_refresh: 0x10,
      tool_install: 0x11,
      tool_uninstall: 0x12,
      tool_update: 0x13,
      tool_dismiss: 0x14,
      agent_tool_toggle: 0x15,
      execute_command: 0x16,
      minibuffer_select: 0x17,
      git_stage_file: 0x18,
      git_unstage_file: 0x19,
      git_discard_file: 0x1A,
      git_stage_all: 0x1B,
      git_unstage_all: 0x1C,
      git_commit: 0x1D,
      git_open_file: 0x1E,
      workspace_rename: 0x1F,
      workspace_set_icon: 0x20,
      workspace_close: 0x21,
      space_leader_chord: 0x22,
      space_leader_retract: 0x23,
      find_pasteboard_search: 0x24,
      board_select_card: 0x25,
      board_close_card: 0x26,
      board_reorder: 0x27,
      board_dispatch_agent: 0x28,
      agent_approve: 0x29,
      agent_request_changes: 0x2A,
      agent_dismiss: 0x2B,
      change_summary_click: 0x2C,
      file_tree_edit_confirm: 0x2D,
      file_tree_edit_cancel: 0x2E,
      scroll_to_line: 0x2F,
      file_tree_delete: 0x30,
      file_tree_rename: 0x31,
      file_tree_duplicate: 0x32,
      file_tree_move: 0x33,
      system_will_sleep: 0x34,
      system_did_wake: 0x35,
      cmd_copy: 0x36,
      cmd_cut: 0x37,
      git_push: 0x38,
      git_pull: 0x39,
      git_fetch: 0x3A,
      git_commit_amend: 0x3B,
      git_pull_and_retry: 0x3C,
      file_tree_open_in_split: 0x3D,
      tab_copy_path: 0x3E,
      hover_open_action: 0x3F,
      file_tree_drop: 0x40,
      fold_toggle_at_line: 0x41,
      git_open_diff: 0x42,
      config_update: 0x43,
      config_query: 0x44,
      notification_dismiss: 0x45,
      notification_action: 0x46
    )
  end

  @spec assert_opcodes(map(), String.t(), keyword(non_neg_integer())) :: :ok
  defp assert_opcodes(schema, category, expected) do
    actual = opcodes_by_name(schema, category)

    for {name, value} <- expected do
      string_name = Atom.to_string(name)
      assert Map.fetch!(actual, string_name) == value
      assert apply(Minga.Protocol.Opcodes, name, []) == value
    end

    assert MapSet.new(Map.keys(actual)) ==
             expected |> Keyword.keys() |> Enum.map(&Atom.to_string/1) |> MapSet.new()
  end

  @spec assert_gui_actions(map(), keyword(non_neg_integer())) :: :ok
  defp assert_gui_actions(schema, expected) do
    actual = schema["gui_actions"] |> Map.new(fn entry -> {entry["name"], entry["value"]} end)

    for {name, value} <- expected do
      string_name = Atom.to_string(name)
      assert Map.fetch!(actual, string_name) == value

      assert apply(Minga.Protocol.Opcodes, String.to_atom("gui_action_" <> string_name), []) ==
               value
    end

    assert MapSet.new(Map.keys(actual)) ==
             expected |> Keyword.keys() |> Enum.map(&Atom.to_string/1) |> MapSet.new()
  end

  @spec opcodes_by_name(map(), String.t()) :: %{String.t() => non_neg_integer()}
  defp opcodes_by_name(schema, category) do
    schema["opcodes"]
    |> Enum.filter(&(&1["category"] == category))
    |> Map.new(fn entry -> {entry["name"], entry["value"]} end)
  end
end
