defmodule Minga.Port.Protocol do
  @moduledoc """
  Binary protocol encoder/decoder for BEAM ↔ Zig communication.

  Messages are length-prefixed binaries (4-byte big-endian header,
  handled by Erlang's `{:packet, 4}` Port option). The payload
  starts with a 1-byte opcode followed by opcode-specific fields.

  ## Input Events (Zig → BEAM)

  | Opcode | Name        | Payload                                                     |
  |--------|-------------|-------------------------------------------------------------|
  | 0x01   | key_press   | `codepoint::32, modifiers::8`                               |
  | 0x02   | resize      | `width::16, height::16`                                     |
  | 0x03   | ready       | `width::16, height::16`                                     |
  | 0x04   | mouse_event | `row::16-signed, col::16-signed, button::8, mods::8, type::8` |

  ## Render Commands (BEAM → Zig)

  | Opcode | Name             | Payload                                                              |
  |--------|------------------|----------------------------------------------------------------------|
  | 0x10   | draw_text        | `row::16, col::16, fg::24, bg::24, attrs::8, text_len::16, text`     |
  | 0x11   | set_cursor       | `row::16, col::16`                                                   |
  | 0x12   | clear            | (empty)                                                              |
  | 0x13   | batch_end        | (empty)                                                              |
  | 0x15   | set_cursor_shape | `shape::8` (BLOCK=0, BEAM=1, UNDERLINE=2)                           |
  | 0x1B   | scroll_region    | `top_row::16, bottom_row::16, delta::16-signed`                      |

  ## Modifier Flags

  | Flag  | Value |
  |-------|-------|
  | SHIFT | 0x01  |
  | CTRL  | 0x02  |
  | ALT   | 0x04  |
  | SUPER | 0x08  |
  """

  # ── Opcodes ──

  # Input events (Zig → BEAM)
  @op_key_press 0x01
  @op_resize 0x02
  @op_ready 0x03
  @op_mouse_event 0x04
  @op_capabilities_updated 0x05
  @op_paste_event 0x06
  @op_gui_action 0x07

  # GUI action types (sub-opcodes within gui_action)
  @gui_action_select_tab 0x01
  @gui_action_close_tab 0x02
  @gui_action_file_tree_click 0x03
  @gui_action_file_tree_toggle 0x04
  @gui_action_completion_select 0x05
  @gui_action_breadcrumb_click 0x06
  @gui_action_toggle_panel 0x07
  @gui_action_new_tab 0x08

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Devicon
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Filetype
  alias Minga.Port.Capabilities

  # Render commands (BEAM → Zig)
  @op_draw_text 0x10
  @op_set_cursor 0x11
  @op_clear 0x12
  @op_batch_end 0x13
  @op_define_region 0x14
  @op_set_cursor_shape 0x15
  @op_set_title 0x16
  @op_set_window_bg 0x17
  @op_clear_region 0x18
  @op_destroy_region 0x19
  @op_set_active_region 0x1A
  @op_scroll_region 0x1B

  # GUI chrome commands (BEAM → Swift)
  @op_gui_file_tree 0x70
  @op_gui_tab_bar 0x1C
  @op_gui_which_key 0x1D
  @op_gui_completion 0x1E
  @op_gui_theme 0x1F
  @op_gui_breadcrumb 0x71
  @op_gui_status_bar 0x72
  @op_gui_picker 0x73
  @op_gui_agent_chat 0x74

  # GUI theme color slot IDs
  @gui_color_editor_bg 0x01
  @gui_color_editor_fg 0x02
  @gui_color_tree_bg 0x03
  @gui_color_tree_fg 0x04
  @gui_color_tree_selection_bg 0x05
  @gui_color_tree_dir_fg 0x06
  @gui_color_tree_active_fg 0x07
  @gui_color_tree_header_bg 0x08
  @gui_color_tree_header_fg 0x09
  @gui_color_tree_separator_fg 0x0A
  @gui_color_tree_git_modified 0x0B
  @gui_color_tree_git_staged 0x0C
  @gui_color_tree_git_untracked 0x0D
  @gui_color_tree_selection_fg 0x0E
  @gui_color_tree_guide_fg 0x0F
  @gui_color_tab_bg 0x10
  @gui_color_tab_active_bg 0x11
  @gui_color_tab_active_fg 0x12
  @gui_color_tab_inactive_fg 0x13
  @gui_color_tab_modified_fg 0x14
  @gui_color_tab_separator_fg 0x15
  @gui_color_tab_close_hover_fg 0x16
  @gui_color_tab_attention_fg 0x17
  @gui_color_popup_bg 0x20
  @gui_color_popup_fg 0x21
  @gui_color_popup_border 0x22
  @gui_color_popup_sel_bg 0x23
  @gui_color_popup_key_fg 0x24
  @gui_color_popup_group_fg 0x25
  @gui_color_popup_desc_fg 0x26
  @gui_color_breadcrumb_bg 0x27
  @gui_color_breadcrumb_fg 0x28
  @gui_color_breadcrumb_separator_fg 0x29
  @gui_color_modeline_bar_bg 0x30
  @gui_color_modeline_bar_fg 0x31
  @gui_color_modeline_info_bg 0x32
  @gui_color_modeline_info_fg 0x33
  @gui_color_mode_normal_bg 0x34
  @gui_color_mode_normal_fg 0x35
  @gui_color_mode_insert_bg 0x36
  @gui_color_mode_insert_fg 0x37
  @gui_color_mode_visual_bg 0x38
  @gui_color_mode_visual_fg 0x39
  @gui_color_statusbar_accent_fg 0x3A
  @gui_color_accent 0x40

  # Highlight commands (BEAM → Zig)
  @op_set_language 0x20
  @op_parse_buffer 0x21
  @op_set_highlight_query 0x22
  @op_load_grammar 0x23
  @op_set_injection_query 0x24
  @op_query_language_at 0x25
  @op_set_fold_query 0x28
  @op_set_indent_query 0x29
  @op_request_indent 0x2A
  @op_set_textobject_query 0x2B
  @op_request_textobject 0x2C
  @op_close_buffer 0x2D

  # Well-known textobject type IDs (match Zig constants)
  @textobj_function 0
  @textobj_class 1
  @textobj_parameter 2
  @textobj_block 3
  @textobj_comment 4
  @textobj_test 5

  # Highlight responses (Zig → BEAM)
  @op_highlight_spans 0x30
  @op_highlight_names 0x31
  @op_grammar_loaded 0x32
  @op_language_at_response 0x33
  @op_injection_ranges 0x34
  @op_text_width 0x35
  @op_fold_ranges 0x36
  @op_indent_result 0x37
  @op_textobject_result 0x38
  @op_textobject_positions 0x39

  # Config commands (BEAM → frontend)
  @op_set_font 0x50

  # Log messages (Zig → BEAM)
  @op_log_message 0x60

  # Cursor shapes
  @cursor_block 0x00
  @cursor_beam 0x01
  @cursor_underline 0x02

  # ── Modifier flags ──

  @mod_shift 0x01
  @mod_ctrl 0x02
  @mod_alt 0x04
  @mod_super 0x08

  # ── Mouse button values (matching libvaxis) ──

  @mouse_left 0x00
  @mouse_middle 0x01
  @mouse_right 0x02
  @mouse_none 0x03
  @mouse_wheel_up 0x40
  @mouse_wheel_down 0x41
  @mouse_wheel_right 0x42
  @mouse_wheel_left 0x43

  # ── Mouse event types ──

  @mouse_press 0x00
  @mouse_release 0x01
  @mouse_motion 0x02
  @mouse_drag 0x03

  # ── Types ──

  @typedoc "Modifier flag bitmask."
  @type modifiers :: non_neg_integer()

  @typedoc "Mouse button identifier."
  @type mouse_button ::
          :left
          | :middle
          | :right
          | :none
          | :wheel_up
          | :wheel_down
          | :wheel_right
          | :wheel_left
          | {:unknown, non_neg_integer()}

  @typedoc "Mouse event type."
  @type mouse_event_type :: :press | :release | :motion | :drag | {:unknown, non_neg_integer()}

  @typedoc "An input event decoded from Zig."
  @type input_event ::
          {:key_press, codepoint :: non_neg_integer(), modifiers()}
          | {:resize, width :: pos_integer(), height :: pos_integer()}
          | {:ready, width :: pos_integer(), height :: pos_integer()}
          | {:ready, width :: pos_integer(), height :: pos_integer(), Capabilities.t()}
          | {:capabilities_updated, Capabilities.t()}
          | {:paste_event, text :: String.t()}
          | {:mouse_event, row :: integer(), col :: integer(), mouse_button(), modifiers(),
             mouse_event_type(), click_count :: pos_integer()}
          | {:highlight_spans, buffer_id :: non_neg_integer(), version :: non_neg_integer(),
             [highlight_span()]}
          | {:highlight_names, buffer_id :: non_neg_integer(), [String.t()]}
          | {:grammar_loaded, success :: boolean(), name :: String.t()}
          | {:injection_ranges, buffer_id :: non_neg_integer(),
             [%{start_byte: non_neg_integer(), end_byte: non_neg_integer(), language: String.t()}]}
          | {:language_at_response, request_id :: non_neg_integer(), language :: String.t()}
          | {:text_width, request_id :: non_neg_integer(), width :: non_neg_integer()}
          | {:fold_ranges, buffer_id :: non_neg_integer(), version :: non_neg_integer(),
             [{start_line :: non_neg_integer(), end_line :: non_neg_integer()}]}
          | {:indent_result, request_id :: non_neg_integer(), line :: non_neg_integer(),
             indent_level :: integer()}
          | {:textobject_result, request_id :: non_neg_integer(),
             result ::
               {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
               | nil}
          | {:textobject_positions, buffer_id :: non_neg_integer(), version :: non_neg_integer(),
             %{atom() => [{non_neg_integer(), non_neg_integer()}]}}
          | {:log_message, level :: String.t(), text :: String.t()}
          | {:gui_action, gui_action()}

  @typedoc "A semantic GUI action from the Swift frontend."
  @type gui_action ::
          {:select_tab, id :: pos_integer()}
          | {:close_tab, id :: pos_integer()}
          | {:file_tree_click, index :: non_neg_integer()}
          | {:file_tree_toggle, index :: non_neg_integer()}
          | {:completion_select, index :: non_neg_integer()}
          | {:breadcrumb_click, segment_index :: non_neg_integer()}
          | {:toggle_panel, panel :: non_neg_integer()}
          | :new_tab

  @typedoc "Cursor shape."
  @type cursor_shape :: :block | :beam | :underline

  @typedoc "A highlight span from tree-sitter."
  @type highlight_span :: %{
          start_byte: non_neg_integer(),
          end_byte: non_neg_integer(),
          capture_id: non_neg_integer()
        }

  @typedoc "Text style attributes."
  @type style :: [
          {:fg, non_neg_integer()}
          | {:bg, non_neg_integer()}
          | {:bold, boolean()}
          | {:underline, boolean()}
          | {:italic, boolean()}
          | {:reverse, boolean()}
        ]

  # ── Modifier helpers ──

  @doc "Returns the SHIFT modifier flag."
  @spec mod_shift() :: modifiers()
  def mod_shift, do: @mod_shift

  @doc "Returns the CTRL modifier flag."
  @spec mod_ctrl() :: modifiers()
  def mod_ctrl, do: @mod_ctrl

  @doc "Returns the ALT modifier flag."
  @spec mod_alt() :: modifiers()
  def mod_alt, do: @mod_alt

  @doc "Returns the SUPER modifier flag."
  @spec mod_super() :: modifiers()
  def mod_super, do: @mod_super

  @doc "Checks if a modifier flag is set."
  @spec has_modifier?(modifiers(), modifiers()) :: boolean()
  def has_modifier?(mods, flag)
      when is_integer(mods) and is_integer(flag) do
    Bitwise.band(mods, flag) != 0
  end

  # ── Encoding (BEAM → Zig) ──

  @doc "Encodes a draw_text command."
  @spec encode_draw(non_neg_integer(), non_neg_integer(), String.t(), style()) :: binary()
  def encode_draw(row, col, text, style \\ [])
      when is_integer(row) and row >= 0 and is_integer(col) and col >= 0 and is_binary(text) do
    fg = Keyword.get(style, :fg, 0xFFFFFF)
    bg = Keyword.get(style, :bg, 0x000000)
    attrs = encode_attrs(style)
    text_len = byte_size(text)

    <<@op_draw_text, row::16, col::16, fg::24, bg::24, attrs::8, text_len::16, text::binary>>
  end

  @doc "Encodes a set_cursor command."
  @spec encode_cursor(non_neg_integer(), non_neg_integer()) :: binary()
  def encode_cursor(row, col)
      when is_integer(row) and row >= 0 and is_integer(col) and col >= 0 do
    <<@op_set_cursor, row::16, col::16>>
  end

  @doc "Encodes a clear screen command."
  @spec encode_clear() :: binary()
  def encode_clear, do: <<@op_clear>>

  @doc "Encodes a batch_end command (triggers render flush)."
  @spec encode_batch_end() :: binary()
  def encode_batch_end, do: <<@op_batch_end>>

  @doc "Encodes a set_cursor_shape command."
  @spec encode_cursor_shape(cursor_shape()) :: binary()
  def encode_cursor_shape(:block), do: <<@op_set_cursor_shape, @cursor_block>>
  def encode_cursor_shape(:beam), do: <<@op_set_cursor_shape, @cursor_beam>>
  def encode_cursor_shape(:underline), do: <<@op_set_cursor_shape, @cursor_underline>>

  @doc "Encodes a set_title command to update the terminal window title."
  @spec encode_set_title(String.t()) :: binary()
  def encode_set_title(title) when is_binary(title) do
    <<@op_set_title, byte_size(title)::16, title::binary>>
  end

  @doc """
  Encodes a set_window_bg command to set the default background color.

  The Zig renderer uses this as the fallback background for any cell
  that doesn't specify an explicit `bg:` value. This prevents cells
  from falling back to the terminal's default background, which may
  not match the editor theme.
  """
  @spec encode_set_window_bg(non_neg_integer()) :: binary()
  def encode_set_window_bg(rgb) when is_integer(rgb) do
    r = Bitwise.band(Bitwise.bsr(rgb, 16), 0xFF)
    g = Bitwise.band(Bitwise.bsr(rgb, 8), 0xFF)
    b = Bitwise.band(rgb, 0xFF)
    <<@op_set_window_bg, r::8, g::8, b::8>>
  end

  @doc """
  Encodes a set_font command to configure the GUI frontend's font.

  The font family is resolved by the frontend using NSFontManager (macOS)
  so both display names ("JetBrains Mono") and PostScript names
  ("JetBrainsMonoNF-Regular") work. The TUI ignores this command.

  Format: `opcode:8, size:16, weight:8, ligatures:8, name_len:16, name:bytes`

  Fields are ordered by category: font identity (size, weight, name) then
  rendering features (ligatures). The variable-length name stays at the end.
  """
  @font_weight_map %{
    thin: 0,
    light: 1,
    regular: 2,
    medium: 3,
    semibold: 4,
    bold: 5,
    heavy: 6,
    black: 7
  }

  @font_weight_reverse Map.new(@font_weight_map, fn {k, v} -> {v, k} end)

  @spec encode_set_font(String.t(), pos_integer(), boolean(), atom()) :: binary()
  def encode_set_font(family, size, ligatures, weight \\ :regular)

  def encode_set_font(family, size, ligatures, weight)
      when is_binary(family) and is_integer(size) and size > 0 and is_boolean(ligatures) and
             is_atom(weight) do
    lig_byte = if ligatures, do: 1, else: 0
    weight_byte = Map.get(@font_weight_map, weight, 2)

    <<@op_set_font, size::16, weight_byte::8, lig_byte::8, byte_size(family)::16, family::binary>>
  end

  # ── Encoding: region commands (BEAM → Zig) ──

  # Region role constants
  @region_editor 0
  @region_modeline 1
  @region_minibuffer 2
  @region_gutter 3
  @region_popup 4
  @region_panel 5
  @region_border 6

  @typedoc "Region role atom."
  @type region_role :: :editor | :modeline | :minibuffer | :gutter | :popup | :panel | :border

  @doc "Encodes a define_region command."
  @spec encode_define_region(
          non_neg_integer(),
          non_neg_integer(),
          region_role(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: binary()
  def encode_define_region(id, parent_id, role, row, col, width, height, z_order) do
    <<@op_define_region, id::16, parent_id::16, encode_region_role(role)::8, row::16, col::16,
      width::16, height::16, z_order::8>>
  end

  @doc "Encodes a clear_region command."
  @spec encode_clear_region(non_neg_integer()) :: binary()
  def encode_clear_region(id), do: <<@op_clear_region, id::16>>

  @doc "Encodes a destroy_region command."
  @spec encode_destroy_region(non_neg_integer()) :: binary()
  def encode_destroy_region(id), do: <<@op_destroy_region, id::16>>

  @doc "Encodes a set_active_region command. Pass 0 to reset to root."
  @spec encode_set_active_region(non_neg_integer()) :: binary()
  def encode_set_active_region(id), do: <<@op_set_active_region, id::16>>

  @doc """
  Encodes a scroll_region command for terminal scroll optimization.

  Tells the Zig renderer to use ANSI scroll region sequences to shift
  content within the given screen row range by `delta` lines, avoiding
  a full redraw.

  * `top_row` / `bottom_row` — screen row range (inclusive) for the scroll region.
  * `delta` — positive = scroll up (content moves up, new lines at bottom),
              negative = scroll down (content moves down, new lines at top).

  Wire format: `opcode(1) + top_row(2) + bottom_row(2) + delta(2, signed)` = 7 bytes.
  """
  @spec encode_scroll_region(non_neg_integer(), non_neg_integer(), integer()) :: binary()
  def encode_scroll_region(top_row, bottom_row, delta)
      when is_integer(top_row) and top_row >= 0 and
             is_integer(bottom_row) and bottom_row >= 0 and
             is_integer(delta) do
    <<@op_scroll_region, top_row::16, bottom_row::16, delta::16-signed>>
  end

  @spec encode_region_role(region_role()) :: non_neg_integer()
  defp encode_region_role(:editor), do: @region_editor
  defp encode_region_role(:modeline), do: @region_modeline
  defp encode_region_role(:minibuffer), do: @region_minibuffer
  defp encode_region_role(:gutter), do: @region_gutter
  defp encode_region_role(:popup), do: @region_popup
  defp encode_region_role(:panel), do: @region_panel
  defp encode_region_role(:border), do: @region_border

  # ── Encoding: incremental content sync (BEAM → Zig) ──

  @op_edit_buffer 0x26

  @typedoc "A single edit delta for incremental content sync."
  @type edit_delta :: %{
          start_byte: non_neg_integer(),
          old_end_byte: non_neg_integer(),
          new_end_byte: non_neg_integer(),
          start_position: {non_neg_integer(), non_neg_integer()},
          old_end_position: {non_neg_integer(), non_neg_integer()},
          new_end_position: {non_neg_integer(), non_neg_integer()},
          inserted_text: String.t()
        }

  @doc """
  Encodes an edit_buffer command with buffer_id, version, and a list of edit deltas.

  Each delta describes a replacement: the range [start_byte, old_end_byte) is
  replaced with `inserted_text`, producing a range [start_byte, new_end_byte).
  """
  @spec encode_edit_buffer(non_neg_integer(), non_neg_integer(), [edit_delta()]) :: binary()
  def encode_edit_buffer(buffer_id, version, edits)
      when is_integer(buffer_id) and buffer_id >= 0 and
             is_integer(version) and is_list(edits) do
    header = <<@op_edit_buffer, buffer_id::32, version::32, length(edits)::16>>

    edit_data =
      for edit <- edits, into: <<>> do
        {sr, sc} = edit.start_position
        {oer, oec} = edit.old_end_position
        {ner, nec} = edit.new_end_position
        text = edit.inserted_text

        <<edit.start_byte::32, edit.old_end_byte::32, edit.new_end_byte::32, sr::32, sc::32,
          oer::32, oec::32, ner::32, nec::32, byte_size(text)::32, text::binary>>
      end

    <<header::binary, edit_data::binary>>
  end

  # ── Encoding: text measurement (BEAM → Zig) ──

  @op_measure_text 0x27

  @doc "Encodes a measure_text request: request_id(4) + text_len(2) + text."
  @spec encode_measure_text(non_neg_integer(), String.t()) :: binary()
  def encode_measure_text(request_id, text)
      when is_integer(request_id) and request_id >= 0 and is_binary(text) do
    <<@op_measure_text, request_id::32, byte_size(text)::16, text::binary>>
  end

  # ── Encoding: highlight commands (BEAM → Zig) ──

  @doc "Encodes a set_language command with buffer_id."
  @spec encode_set_language(non_neg_integer(), String.t()) :: binary()
  def encode_set_language(buffer_id, name)
      when is_integer(buffer_id) and buffer_id >= 0 and is_binary(name) do
    <<@op_set_language, buffer_id::32, byte_size(name)::16, name::binary>>
  end

  @doc "Encodes a parse_buffer command with buffer_id and version counter."
  @spec encode_parse_buffer(non_neg_integer(), non_neg_integer(), String.t()) :: binary()
  def encode_parse_buffer(buffer_id, version, source)
      when is_integer(buffer_id) and buffer_id >= 0 and
             is_integer(version) and version >= 0 and is_binary(source) do
    <<@op_parse_buffer, buffer_id::32, version::32, byte_size(source)::32, source::binary>>
  end

  @doc "Encodes a set_highlight_query command with buffer_id."
  @spec encode_set_highlight_query(non_neg_integer(), String.t()) :: binary()
  def encode_set_highlight_query(buffer_id, query)
      when is_integer(buffer_id) and buffer_id >= 0 and is_binary(query) do
    <<@op_set_highlight_query, buffer_id::32, byte_size(query)::32, query::binary>>
  end

  @doc "Encodes a set_injection_query command with buffer_id."
  @spec encode_set_injection_query(non_neg_integer(), String.t()) :: binary()
  def encode_set_injection_query(buffer_id, query)
      when is_integer(buffer_id) and buffer_id >= 0 and is_binary(query) do
    <<@op_set_injection_query, buffer_id::32, byte_size(query)::32, query::binary>>
  end

  @doc "Encodes a set_fold_query command with buffer_id."
  @spec encode_set_fold_query(non_neg_integer(), String.t()) :: binary()
  def encode_set_fold_query(buffer_id, query)
      when is_integer(buffer_id) and buffer_id >= 0 and is_binary(query) do
    <<@op_set_fold_query, buffer_id::32, byte_size(query)::32, query::binary>>
  end

  @doc "Encodes a set_indent_query command with buffer_id."
  @spec encode_set_indent_query(non_neg_integer(), String.t()) :: binary()
  def encode_set_indent_query(buffer_id, query)
      when is_integer(buffer_id) and buffer_id >= 0 and is_binary(query) do
    <<@op_set_indent_query, buffer_id::32, byte_size(query)::32, query::binary>>
  end

  @doc "Encodes a request_indent command: buffer_id(4) + request_id(4) + line(4)."
  @spec encode_request_indent(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: binary()
  def encode_request_indent(buffer_id, request_id, line)
      when is_integer(buffer_id) and buffer_id >= 0 and
             is_integer(request_id) and is_integer(line) do
    <<@op_request_indent, buffer_id::32, request_id::32, line::32>>
  end

  @doc "Encodes a set_textobject_query command with buffer_id."
  @spec encode_set_textobject_query(non_neg_integer(), String.t()) :: binary()
  def encode_set_textobject_query(buffer_id, query)
      when is_integer(buffer_id) and buffer_id >= 0 and is_binary(query) do
    <<@op_set_textobject_query, buffer_id::32, byte_size(query)::32, query::binary>>
  end

  @doc "Encodes a request_textobject command: buffer_id(4) + request_id(4) + row(4) + col(4) + name_len(2) + name."
  @spec encode_request_textobject(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t()
        ) ::
          binary()
  def encode_request_textobject(buffer_id, request_id, row, col, capture_name)
      when is_integer(buffer_id) and buffer_id >= 0 and
             is_integer(request_id) and is_integer(row) and is_integer(col) and
             is_binary(capture_name) do
    <<@op_request_textobject, buffer_id::32, request_id::32, row::32, col::32,
      byte_size(capture_name)::16, capture_name::binary>>
  end

  @doc "Encodes a load_grammar command."
  @spec encode_load_grammar(String.t(), String.t()) :: binary()
  def encode_load_grammar(name, path) when is_binary(name) and is_binary(path) do
    <<@op_load_grammar, byte_size(name)::16, name::binary, byte_size(path)::16, path::binary>>
  end

  @doc "Encodes a query_language_at request: buffer_id(4) + request_id(4) + byte_offset(4)."
  @spec encode_query_language_at(non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          binary()
  def encode_query_language_at(buffer_id, request_id, byte_offset)
      when is_integer(buffer_id) and buffer_id >= 0 and
             is_integer(request_id) and is_integer(byte_offset) do
    <<@op_query_language_at, buffer_id::32, request_id::32, byte_offset::32>>
  end

  @doc "Encodes a close_buffer command: buffer_id(4)."
  @spec encode_close_buffer(non_neg_integer()) :: binary()
  def encode_close_buffer(buffer_id)
      when is_integer(buffer_id) and buffer_id >= 0 do
    <<@op_close_buffer, buffer_id::32>>
  end

  # ── GUI chrome encoding ──

  @doc """
  Encodes a gui_theme command with all theme colors for SwiftUI chrome.

  Takes a `Theme.t()` and produces a binary with `{slot_id:u8, r:u8, g:u8, b:u8}`
  entries for every color slot the GUI needs. Colors that are nil are skipped.
  """
  @spec encode_gui_theme(Minga.Theme.t()) :: binary()
  def encode_gui_theme(%Minga.Theme{} = theme) do
    colors =
      build_gui_theme_colors(theme)
      |> Enum.reject(fn {_slot, color} -> is_nil(color) end)

    count = length(colors)

    entries =
      Enum.map(colors, fn {slot, rgb} ->
        r = Bitwise.bsr(Bitwise.band(rgb, 0xFF0000), 16)
        g = Bitwise.bsr(Bitwise.band(rgb, 0x00FF00), 8)
        b = Bitwise.band(rgb, 0x0000FF)
        <<slot::8, r::8, g::8, b::8>>
      end)

    IO.iodata_to_binary([@op_gui_theme, <<count::8>> | entries])
  end

  @spec build_gui_theme_colors(Minga.Theme.t()) ::
          [{non_neg_integer(), non_neg_integer() | nil}]
  defp build_gui_theme_colors(theme) do
    e = theme.editor
    t = theme.tree
    tb = theme.tab_bar
    p = theme.popup
    ml = theme.modeline

    mode_color = fn mode ->
      case Map.get(ml.mode_colors || %{}, mode) do
        {fg, bg} -> {fg, bg}
        _ -> {ml.bar_fg, ml.bar_bg}
      end
    end

    {normal_fg, normal_bg} = mode_color.(:normal)
    {insert_fg, insert_bg} = mode_color.(:insert)
    {visual_fg, visual_bg} = mode_color.(:visual)

    [
      {@gui_color_editor_bg, e.bg},
      {@gui_color_editor_fg, e.fg},
      {@gui_color_tree_bg, t.bg},
      {@gui_color_tree_fg, t.fg},
      {@gui_color_tree_selection_bg, t.cursor_bg},
      {@gui_color_tree_dir_fg, t.dir_fg},
      {@gui_color_tree_active_fg, t.active_fg},
      {@gui_color_tree_header_bg, t.header_bg},
      {@gui_color_tree_header_fg, t.header_fg},
      {@gui_color_tree_separator_fg, t.separator_fg},
      {@gui_color_tree_git_modified, t.git_modified_fg},
      {@gui_color_tree_git_staged, t.git_staged_fg},
      {@gui_color_tree_git_untracked, t.git_untracked_fg},
      {@gui_color_tree_selection_fg, e.fg},
      {@gui_color_tree_guide_fg, t.separator_fg},
      {@gui_color_tab_bg, tb && tb.bg},
      {@gui_color_tab_active_bg, tb && tb.active_bg},
      {@gui_color_tab_active_fg, tb && tb.active_fg},
      {@gui_color_tab_inactive_fg, tb && tb.inactive_fg},
      {@gui_color_tab_modified_fg, tb && tb.modified_fg},
      {@gui_color_tab_separator_fg, tb && tb.separator_fg},
      {@gui_color_tab_close_hover_fg, tb && tb.close_hover_fg},
      {@gui_color_tab_attention_fg, tb && tb.attention_fg},
      {@gui_color_popup_bg, p.bg},
      {@gui_color_popup_fg, p.fg},
      {@gui_color_popup_border, p.border_fg},
      {@gui_color_popup_sel_bg, p.sel_bg},
      {@gui_color_popup_key_fg, p.key_fg},
      {@gui_color_popup_group_fg, p.group_fg},
      {@gui_color_popup_desc_fg, p.fg},
      {@gui_color_breadcrumb_bg, ml.bar_bg},
      {@gui_color_breadcrumb_fg, ml.info_fg},
      {@gui_color_breadcrumb_separator_fg, t.separator_fg},
      {@gui_color_modeline_bar_bg, ml.bar_bg},
      {@gui_color_modeline_bar_fg, ml.bar_fg},
      {@gui_color_modeline_info_bg, ml.info_bg},
      {@gui_color_modeline_info_fg, ml.info_fg},
      {@gui_color_mode_normal_bg, normal_bg},
      {@gui_color_mode_normal_fg, normal_fg},
      {@gui_color_mode_insert_bg, insert_bg},
      {@gui_color_mode_insert_fg, insert_fg},
      {@gui_color_mode_visual_bg, visual_bg},
      {@gui_color_mode_visual_fg, visual_fg},
      {@gui_color_statusbar_accent_fg, t.active_fg},
      {@gui_color_accent, t.active_fg}
    ]
  end

  @doc """
  Encodes a gui_tab_bar command with the current tab bar state.

  Each tab entry includes: flags byte (is_active, is_dirty, is_agent,
  has_attention, agent_status in upper bits), tab id, Nerd Font icon,
  and display label.
  """
  @spec encode_gui_tab_bar(TabBar.t(), pid() | nil) :: binary()
  def encode_gui_tab_bar(%TabBar{} = tb, active_win_buffer \\ nil) do
    active_index = TabBar.active_index(tb)

    entries =
      Enum.map(tb.tabs, fn tab ->
        encode_gui_tab_entry(tab, tb.active_id, active_win_buffer)
      end)

    IO.iodata_to_binary([
      @op_gui_tab_bar,
      <<active_index::8, length(tb.tabs)::8>>
      | entries
    ])
  end

  @spec encode_gui_tab_entry(Tab.t(), pos_integer(), pid() | nil) :: binary()
  defp encode_gui_tab_entry(tab, active_id, active_win_buffer) do
    is_active = if tab.id == active_id, do: 1, else: 0
    flags = build_tab_flags(tab, is_active, active_win_buffer)

    icon = tab_icon(tab)
    icon_bytes = :erlang.iolist_to_binary([icon])
    label_bytes = :erlang.iolist_to_binary([tab.label])

    <<flags::8, tab.id::32, byte_size(icon_bytes)::8, icon_bytes::binary,
      byte_size(label_bytes)::16, label_bytes::binary>>
  end

  @spec build_tab_flags(Tab.t(), 0 | 1, pid() | nil) :: non_neg_integer()
  defp build_tab_flags(tab, is_active, active_win_buffer) do
    is_dirty = tab_dirty_bit(tab, is_active, active_win_buffer)
    is_agent = if tab.kind == :agent, do: 1, else: 0
    has_attention = if tab.attention, do: 1, else: 0
    agent_status = encode_agent_status(tab.agent_status)

    Bitwise.bor(
      Bitwise.bor(is_active, Bitwise.bsl(is_dirty, 1)),
      Bitwise.bor(
        Bitwise.bor(Bitwise.bsl(is_agent, 2), Bitwise.bsl(has_attention, 3)),
        Bitwise.bsl(agent_status, 4)
      )
    )
  end

  @spec tab_dirty_bit(Tab.t(), 0 | 1, pid() | nil) :: 0 | 1
  defp tab_dirty_bit(%{kind: :agent}, _is_active, _buf), do: 0

  defp tab_dirty_bit(tab, is_active, active_win_buffer) do
    pid = resolve_tab_buffer(tab, is_active, active_win_buffer)
    if pid && BufferServer.dirty?(pid), do: 1, else: 0
  end

  @spec resolve_tab_buffer(Tab.t(), 0 | 1, pid() | nil) :: pid() | nil
  defp resolve_tab_buffer(%{context: %{buffers: %{active: pid}}}, _is_active, _buf)
       when is_pid(pid),
       do: pid

  defp resolve_tab_buffer(_tab, 1, buf) when is_pid(buf), do: buf
  defp resolve_tab_buffer(_tab, _is_active, _buf), do: nil

  @spec encode_agent_status(atom() | nil) :: non_neg_integer()
  defp encode_agent_status(:idle), do: 0
  defp encode_agent_status(:thinking), do: 1
  defp encode_agent_status(:tool_executing), do: 2
  defp encode_agent_status(:error), do: 3
  defp encode_agent_status(_), do: 0

  @spec tab_icon(Tab.t()) :: String.t()
  defp tab_icon(%{kind: :agent}), do: Devicon.icon(:agent)
  defp tab_icon(%{kind: :file, label: label}), do: Devicon.icon(Filetype.detect(label))

  @doc """
  Encodes a gui_file_tree command with the visible file tree entries.

  Sends: selected_index, tree_width, entry_count, then per entry:
  flags (is_dir, is_expanded), depth, git_status, icon, name.
  """
  @spec encode_gui_file_tree(Minga.FileTree.t()) :: binary()
  def encode_gui_file_tree(%Minga.FileTree{} = tree) do
    entries = Minga.FileTree.visible_entries(tree)
    count = length(entries)

    entry_binaries =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} ->
        encode_file_tree_entry(entry, tree, index == tree.cursor)
      end)

    IO.iodata_to_binary([
      @op_gui_file_tree,
      <<tree.cursor::16, tree.width::16, count::16>>
      | entry_binaries
    ])
  end

  @spec encode_file_tree_entry(Minga.FileTree.entry(), Minga.FileTree.t(), boolean()) :: binary()
  defp encode_file_tree_entry(entry, tree, is_selected?) do
    is_dir = if entry[:dir?], do: 1, else: 0
    is_expanded = if entry[:dir?] && MapSet.member?(tree.expanded, entry.path), do: 1, else: 0
    selected_bit = if is_selected?, do: 1, else: 0

    flags =
      Bitwise.bor(
        is_dir,
        Bitwise.bor(Bitwise.bsl(is_expanded, 1), Bitwise.bsl(selected_bit, 2))
      )

    git_status = encode_git_status(Map.get(tree.git_status, entry.path))

    icon = file_tree_icon(entry)
    icon_bytes = :erlang.iolist_to_binary([icon])
    name_bytes = :erlang.iolist_to_binary([entry.name])

    <<flags::8, entry.depth::8, git_status::8, byte_size(icon_bytes)::8, icon_bytes::binary,
      byte_size(name_bytes)::16, name_bytes::binary>>
  end

  # Nerd Font folder icon (nf-md-folder)
  @folder_icon "\u{F024B}"

  @spec file_tree_icon(Minga.FileTree.entry()) :: String.t()
  defp file_tree_icon(%{dir?: true}), do: @folder_icon
  defp file_tree_icon(%{name: name}), do: Devicon.icon(Filetype.detect(name))

  @spec encode_git_status(atom() | nil) :: non_neg_integer()
  defp encode_git_status(nil), do: 0
  defp encode_git_status(:modified), do: 1
  defp encode_git_status(:staged), do: 2
  defp encode_git_status(:untracked), do: 3
  defp encode_git_status(:conflict), do: 4
  defp encode_git_status(:ignored), do: 5
  defp encode_git_status(_), do: 0

  # ── Completion ──

  @doc "Encodes a gui_completion command."
  @spec encode_gui_completion(Minga.Completion.t() | nil, non_neg_integer(), non_neg_integer()) ::
          binary()
  def encode_gui_completion(nil, _row, _col), do: <<@op_gui_completion, 0::8>>

  def encode_gui_completion(%Minga.Completion{filtered: []}, _row, _col) do
    <<@op_gui_completion, 0::8>>
  end

  def encode_gui_completion(%Minga.Completion{} = comp, cursor_row, cursor_col) do
    items = Enum.take(comp.filtered, comp.max_visible)

    entries =
      Enum.map(items, fn item ->
        kind_byte = encode_completion_kind(item.kind)
        label = :erlang.iolist_to_binary([item.label])
        detail = :erlang.iolist_to_binary([item.detail || ""])

        <<kind_byte::8, byte_size(label)::16, label::binary, byte_size(detail)::16,
          detail::binary>>
      end)

    IO.iodata_to_binary([
      @op_gui_completion,
      <<1::8, cursor_row::16, cursor_col::16, comp.selected::16, length(items)::16>>
      | entries
    ])
  end

  @spec encode_completion_kind(atom()) :: non_neg_integer()
  defp encode_completion_kind(:function), do: 1
  defp encode_completion_kind(:method), do: 2
  defp encode_completion_kind(:variable), do: 3
  defp encode_completion_kind(:field), do: 4
  defp encode_completion_kind(:module), do: 5
  defp encode_completion_kind(:keyword), do: 7
  defp encode_completion_kind(:snippet), do: 8
  defp encode_completion_kind(:constant), do: 9
  defp encode_completion_kind(:struct), do: 11
  defp encode_completion_kind(:enum), do: 12
  defp encode_completion_kind(_), do: 0

  # ── Which-key ──

  @doc "Encodes a gui_which_key command."
  @spec encode_gui_which_key(Minga.Editor.State.WhichKey.t()) :: binary()
  def encode_gui_which_key(%{show: false}), do: <<@op_gui_which_key, 0::8>>
  def encode_gui_which_key(%{show: true, node: nil}), do: <<@op_gui_which_key, 0::8>>

  def encode_gui_which_key(%{show: true, node: node, prefix_keys: prefix_keys, page: page}) do
    bindings = Minga.WhichKey.bindings_from_node(node)
    prefix_bytes = prefix_keys |> Enum.join(" ") |> :erlang.iolist_to_binary()

    page_size = 20
    page_count = max(div(length(bindings) + page_size - 1, page_size), 1)
    page_bindings = bindings |> Enum.drop(page * page_size) |> Enum.take(page_size)

    entries =
      Enum.map(page_bindings, fn b ->
        kind_byte = if b.kind == :group, do: 1, else: 0
        key = :erlang.iolist_to_binary([b.key])
        desc = :erlang.iolist_to_binary([b.description])
        icon = :erlang.iolist_to_binary([b.icon || ""])

        <<kind_byte::8, byte_size(key)::8, key::binary, byte_size(desc)::16, desc::binary,
          byte_size(icon)::8, icon::binary>>
      end)

    IO.iodata_to_binary([
      @op_gui_which_key,
      <<1::8, byte_size(prefix_bytes)::16, prefix_bytes::binary, page::8, page_count::8,
        length(page_bindings)::16>>
      | entries
    ])
  end

  # ── Breadcrumb ──

  @doc "Encodes a gui_breadcrumb command."
  @spec encode_gui_breadcrumb(String.t() | nil, String.t()) :: binary()
  def encode_gui_breadcrumb(nil, _root), do: <<@op_gui_breadcrumb, 0::8>>

  def encode_gui_breadcrumb(file_path, root) do
    segments = file_path |> Path.relative_to(root) |> Path.split()

    entries =
      Enum.map(segments, fn seg ->
        seg_bytes = :erlang.iolist_to_binary([seg])
        <<byte_size(seg_bytes)::16, seg_bytes::binary>>
      end)

    IO.iodata_to_binary([@op_gui_breadcrumb, <<length(segments)::8>> | entries])
  end

  # ── Status bar ──

  @doc "Encodes a gui_status_bar command."
  @spec encode_gui_status_bar(map()) :: binary()
  def encode_gui_status_bar(data) do
    mode_byte = encode_vim_mode(data.mode)
    lsp_byte = encode_lsp_status(data[:lsp_status])
    flags = build_status_flags(data)

    git_branch = :erlang.iolist_to_binary([data[:git_branch] || ""])
    message = :erlang.iolist_to_binary([data[:status_msg] || ""])
    filetype = :erlang.iolist_to_binary([Atom.to_string(data[:filetype] || :text)])

    <<@op_gui_status_bar, mode_byte::8, data.cursor_line::32, data.cursor_col::32,
      data.line_count::32, flags::8, lsp_byte::8, byte_size(git_branch)::8, git_branch::binary,
      byte_size(message)::16, message::binary, byte_size(filetype)::8, filetype::binary>>
  end

  @spec encode_vim_mode(atom()) :: non_neg_integer()
  defp encode_vim_mode(:normal), do: 0
  defp encode_vim_mode(:insert), do: 1
  defp encode_vim_mode(:visual), do: 2
  defp encode_vim_mode(:command), do: 3
  defp encode_vim_mode(:operator_pending), do: 4
  defp encode_vim_mode(:search), do: 5
  defp encode_vim_mode(:search_prompt), do: 5
  defp encode_vim_mode(:replace), do: 6
  defp encode_vim_mode(_), do: 0

  @spec encode_lsp_status(atom() | nil) :: non_neg_integer()
  defp encode_lsp_status(:ready), do: 1
  defp encode_lsp_status(:initializing), do: 2
  defp encode_lsp_status(:starting), do: 3
  defp encode_lsp_status(:error), do: 4
  defp encode_lsp_status(_), do: 0

  @spec build_status_flags(map()) :: non_neg_integer()
  defp build_status_flags(data) do
    has_lsp = if data[:lsp_status] && data[:lsp_status] != :none, do: 1, else: 0
    has_git = if data[:git_branch], do: 1, else: 0
    is_dirty = if data[:dirty_marker] && data[:dirty_marker] != "", do: 1, else: 0
    Bitwise.bor(has_lsp, Bitwise.bor(Bitwise.bsl(has_git, 1), Bitwise.bsl(is_dirty, 2)))
  end

  # ── Picker ──

  @doc "Encodes a gui_picker command."
  @spec encode_gui_picker(Minga.Picker.t() | nil) :: binary()
  def encode_gui_picker(nil), do: <<@op_gui_picker, 0::8>>

  def encode_gui_picker(%Minga.Picker{} = picker) do
    items = Enum.take(picker.filtered, picker.max_visible)
    title_bytes = :erlang.iolist_to_binary([picker.title])
    query_bytes = :erlang.iolist_to_binary([picker.query])

    entries =
      Enum.map(items, fn item ->
        label_bytes = :erlang.iolist_to_binary([item.label])
        desc_bytes = :erlang.iolist_to_binary([item.description || ""])
        icon_color = item.icon_color || 0

        <<icon_color::24, byte_size(label_bytes)::16, label_bytes::binary,
          byte_size(desc_bytes)::16, desc_bytes::binary>>
      end)

    IO.iodata_to_binary([
      @op_gui_picker,
      <<1::8, picker.selected::16, byte_size(title_bytes)::16, title_bytes::binary,
        byte_size(query_bytes)::16, query_bytes::binary, length(items)::16>>
      | entries
    ])
  end

  # ── Agent chat ──

  @doc "Encodes a gui_agent_chat command with conversation messages."
  @spec encode_gui_agent_chat(map()) :: binary()
  def encode_gui_agent_chat(%{visible: false}) do
    <<@op_gui_agent_chat, 0::8>>
  end

  def encode_gui_agent_chat(%{
        visible: true,
        messages: messages,
        status: status,
        model: model,
        prompt: prompt
      }) do
    status_byte = encode_agent_chat_status(status)
    model_bytes = :erlang.iolist_to_binary([model || ""])
    prompt_bytes = :erlang.iolist_to_binary([prompt || ""])

    msg_binaries =
      messages
      |> Enum.take(100)
      |> Enum.map(&encode_chat_message/1)

    IO.iodata_to_binary([
      @op_gui_agent_chat,
      <<1::8, status_byte::8, byte_size(model_bytes)::16, model_bytes::binary,
        byte_size(prompt_bytes)::16, prompt_bytes::binary, length(msg_binaries)::16>>
      | msg_binaries
    ])
  end

  @spec encode_chat_message(Minga.Agent.Message.t()) :: binary()
  defp encode_chat_message({:user, text}) do
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x01::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  defp encode_chat_message({:user, text, _attachments}) do
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x01::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  defp encode_chat_message({:assistant, text}) do
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x02::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  defp encode_chat_message({:thinking, text, collapsed}) do
    collapsed_byte = if collapsed, do: 1, else: 0
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x03::8, collapsed_byte::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  defp encode_chat_message({:tool_call, tc}) do
    name_bytes = :erlang.iolist_to_binary([tc.name])
    result_bytes = :erlang.iolist_to_binary([tc.result || ""])

    status_byte =
      case tc.status do
        :running -> 0
        :complete -> 1
        :error -> 2
      end

    duration = tc.duration_ms || 0
    error_byte = if tc.is_error, do: 1, else: 0
    collapsed_byte = if tc.collapsed, do: 1, else: 0

    <<0x04::8, status_byte::8, error_byte::8, collapsed_byte::8, duration::32,
      byte_size(name_bytes)::16, name_bytes::binary, byte_size(result_bytes)::32,
      result_bytes::binary>>
  end

  defp encode_chat_message({:system, text, level}) do
    level_byte = if level == :error, do: 1, else: 0
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x05::8, level_byte::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  defp encode_chat_message({:usage, u}) do
    cost_int = round((u.cost || 0.0) * 1_000_000)
    <<0x06::8, u.input::32, u.output::32, u.cache_read::32, u.cache_write::32, cost_int::32>>
  end

  @spec encode_agent_chat_status(atom()) :: non_neg_integer()
  defp encode_agent_chat_status(:idle), do: 0
  defp encode_agent_chat_status(:thinking), do: 1
  defp encode_agent_chat_status(:tool_executing), do: 2
  defp encode_agent_chat_status(:error), do: 3
  defp encode_agent_chat_status(_), do: 0

  # ── Decoding (Zig → BEAM) ──

  @doc "Decodes an input event from a binary payload."
  @spec decode_event(binary()) :: {:ok, input_event()} | {:error, :unknown_opcode | :malformed}
  def decode_event(<<@op_key_press, codepoint::32, modifiers::8>>) do
    {:ok, {:key_press, codepoint, modifiers}}
  end

  def decode_event(<<@op_resize, width::16, height::16>>) do
    {:ok, {:resize, width, height}}
  end

  # Extended ready with capabilities: opcode(1) + width(2) + height(2) + caps_version(1) + caps_len(1) + caps_data
  def decode_event(
        <<@op_ready, width::16, height::16, _caps_version::8, caps_len::8,
          caps_data::binary-size(caps_len)>>
      ) do
    caps = Capabilities.from_binary(caps_data)
    {:ok, {:ready, width, height, caps}}
  end

  # Short ready (backward compat with old frontends).
  def decode_event(<<@op_ready, width::16, height::16>>) do
    {:ok, {:ready, width, height}}
  end

  # Capabilities updated event (sent after async capability detection).
  def decode_event(
        <<@op_capabilities_updated, _caps_version::8, caps_len::8,
          caps_data::binary-size(caps_len)>>
      ) do
    caps = Capabilities.from_binary(caps_data)
    {:ok, {:capabilities_updated, caps}}
  end

  # 9-byte mouse event with click_count (new protocol)
  def decode_event(
        <<@op_mouse_event, row::16-signed, col::16-signed, button::8, mods::8, event_type::8,
          click_count::8>>
      ) do
    {:ok,
     {:mouse_event, row, col, decode_mouse_button(button), mods,
      decode_mouse_event_type(event_type), click_count}}
  end

  # 8-byte mouse event without click_count (backward compat with old frontends)
  def decode_event(
        <<@op_mouse_event, row::16-signed, col::16-signed, button::8, mods::8, event_type::8>>
      ) do
    {:ok,
     {:mouse_event, row, col, decode_mouse_button(button), mods,
      decode_mouse_event_type(event_type), 1}}
  end

  # Paste event: opcode(1) + text_len(2, big-endian) + text(text_len)
  def decode_event(<<@op_paste_event, text_len::16, text::binary-size(text_len)>>) do
    {:ok, {:paste_event, text}}
  end

  # GUI action: opcode(1) + action_type(1) + payload
  def decode_event(<<@op_gui_action, action_type::8, rest::binary>>) do
    case decode_gui_action(action_type, rest) do
      {:ok, action} -> {:ok, {:gui_action, action}}
      :error -> {:error, :malformed}
    end
  end

  def decode_event(<<@op_highlight_spans, buffer_id::32, version::32, count::32, rest::binary>>) do
    case decode_spans(rest, count, []) do
      {:ok, spans} -> {:ok, {:highlight_spans, buffer_id, version, spans}}
      :error -> {:error, :malformed}
    end
  end

  def decode_event(<<@op_highlight_names, buffer_id::32, count::16, rest::binary>>) do
    case decode_names(rest, count, []) do
      {:ok, names} -> {:ok, {:highlight_names, buffer_id, names}}
      :error -> {:error, :malformed}
    end
  end

  def decode_event(<<@op_grammar_loaded, success::8, name_len::16, name::binary-size(name_len)>>) do
    {:ok, {:grammar_loaded, success == 1, name}}
  end

  def decode_event(
        <<@op_language_at_response, request_id::32, name_len::16, name::binary-size(name_len)>>
      ) do
    {:ok, {:language_at_response, request_id, name}}
  end

  def decode_event(<<@op_injection_ranges, buffer_id::32, count::16, rest::binary>>) do
    {:ok, {:injection_ranges, buffer_id, decode_injection_ranges(rest, count, [])}}
  end

  def decode_event(<<@op_text_width, request_id::32, width::16>>) do
    {:ok, {:text_width, request_id, width}}
  end

  def decode_event(<<@op_fold_ranges, buffer_id::32, version::32, count::32, rest::binary>>) do
    case decode_fold_ranges(rest, count, []) do
      {:ok, ranges} -> {:ok, {:fold_ranges, buffer_id, version, ranges}}
      :error -> {:error, :malformed}
    end
  end

  def decode_event(<<@op_indent_result, request_id::32, line::32, indent_level::32-signed>>) do
    {:ok, {:indent_result, request_id, line, indent_level}}
  end

  def decode_event(
        <<@op_textobject_result, request_id::32, 1, start_row::32, start_col::32, end_row::32,
          end_col::32>>
      ) do
    {:ok, {:textobject_result, request_id, {start_row, start_col, end_row, end_col}}}
  end

  def decode_event(<<@op_textobject_result, request_id::32, 0>>) do
    {:ok, {:textobject_result, request_id, nil}}
  end

  def decode_event(
        <<@op_textobject_positions, buffer_id::32, version::32, count::32, entries::binary>>
      ) do
    positions = decode_textobject_entries(entries, count, %{})
    {:ok, {:textobject_positions, buffer_id, version, positions}}
  end

  def decode_event(<<@op_log_message, level_byte::8, msg_len::16, msg::binary-size(msg_len)>>) do
    level = decode_log_level(level_byte)
    {:ok, {:log_message, level, msg}}
  end

  def decode_event(<<opcode::8, _rest::binary>>)
      when opcode in [
             @op_key_press,
             @op_resize,
             @op_ready,
             @op_mouse_event,
             @op_capabilities_updated
           ] do
    {:error, :malformed}
  end

  def decode_event(<<_opcode::8, _rest::binary>>) do
    {:error, :unknown_opcode}
  end

  def decode_event(<<>>) do
    {:error, :malformed}
  end

  # ── Decoding render commands (for testing round-trips) ──

  @doc "Decodes a render command from a binary payload (primarily for testing)."
  @spec decode_command(binary()) ::
          {:ok,
           :clear
           | :batch_end
           | {:draw_text, map()}
           | {:set_cursor, non_neg_integer(), non_neg_integer()}
           | {:set_cursor_shape, cursor_shape()}}
          | {:error, :unknown_opcode | :malformed}
  def decode_command(
        <<@op_draw_text, row::16, col::16, fg::24, bg::24, attrs::8, text_len::16,
          text::binary-size(text_len)>>
      ) do
    {:ok,
     {:draw_text, %{row: row, col: col, fg: fg, bg: bg, attrs: decode_attrs(attrs), text: text}}}
  end

  def decode_command(<<@op_set_cursor, row::16, col::16>>) do
    {:ok, {:set_cursor, row, col}}
  end

  def decode_command(<<@op_clear>>) do
    {:ok, :clear}
  end

  def decode_command(<<@op_batch_end>>) do
    {:ok, :batch_end}
  end

  def decode_command(<<@op_set_cursor_shape, @cursor_block>>) do
    {:ok, {:set_cursor_shape, :block}}
  end

  def decode_command(<<@op_set_cursor_shape, @cursor_beam>>) do
    {:ok, {:set_cursor_shape, :beam}}
  end

  def decode_command(<<@op_set_cursor_shape, @cursor_underline>>) do
    {:ok, {:set_cursor_shape, :underline}}
  end

  def decode_command(<<@op_set_title, len::16, title::binary-size(len)>>) do
    {:ok, {:set_title, title}}
  end

  def decode_command(<<@op_scroll_region, top_row::16, bottom_row::16, delta::16-signed>>) do
    {:ok, {:scroll_region, top_row, bottom_row, delta}}
  end

  def decode_command(
        <<@op_set_font, size::16, weight_byte::8, lig::8, name_len::16,
          name::binary-size(name_len)>>
      ) do
    weight = Map.get(@font_weight_reverse, weight_byte, :regular)
    {:ok, {:set_font, name, size, weight, lig == 1}}
  end

  def decode_command(<<_opcode::8, _rest::binary>>) do
    {:error, :unknown_opcode}
  end

  def decode_command(<<>>) do
    {:error, :malformed}
  end

  @spec decode_textobject_entries(binary(), non_neg_integer(), map()) :: map()
  defp decode_textobject_entries(_data, 0, acc) do
    Map.new(acc, fn {type, positions} -> {type, Enum.reverse(positions)} end)
  end

  defp decode_textobject_entries(
         <<type_id::8, row::32, col::32, rest::binary>>,
         remaining,
         acc
       ) do
    type_atom = textobj_type_to_atom(type_id)
    existing = Map.get(acc, type_atom, [])
    updated = Map.put(acc, type_atom, [{row, col} | existing])
    decode_textobject_entries(rest, remaining - 1, updated)
  end

  defp decode_textobject_entries(_, _, acc) do
    Map.new(acc, fn {type, positions} -> {type, Enum.reverse(positions)} end)
  end

  @spec textobj_type_to_atom(non_neg_integer()) :: atom()
  defp textobj_type_to_atom(@textobj_function), do: :function
  defp textobj_type_to_atom(@textobj_class), do: :class
  defp textobj_type_to_atom(@textobj_parameter), do: :parameter
  defp textobj_type_to_atom(@textobj_block), do: :block
  defp textobj_type_to_atom(@textobj_comment), do: :comment
  defp textobj_type_to_atom(@textobj_test), do: :test
  defp textobj_type_to_atom(_), do: :unknown

  # ── Private ──

  @attr_bold 0x01
  @attr_underline 0x02
  @attr_italic 0x04
  @attr_reverse 0x08

  @spec encode_attrs(style()) :: non_neg_integer()
  defp encode_attrs(style) do
    import Bitwise

    0
    |> then(fn a -> if Keyword.get(style, :bold, false), do: a ||| @attr_bold, else: a end)
    |> then(fn a ->
      if Keyword.get(style, :underline, false), do: a ||| @attr_underline, else: a
    end)
    |> then(fn a -> if Keyword.get(style, :italic, false), do: a ||| @attr_italic, else: a end)
    |> then(fn a -> if Keyword.get(style, :reverse, false), do: a ||| @attr_reverse, else: a end)
  end

  @spec decode_attrs(non_neg_integer()) :: [atom()]
  defp decode_attrs(attrs) do
    import Bitwise

    []
    |> then(fn a -> if (attrs &&& @attr_bold) != 0, do: [:bold | a], else: a end)
    |> then(fn a -> if (attrs &&& @attr_underline) != 0, do: [:underline | a], else: a end)
    |> then(fn a -> if (attrs &&& @attr_italic) != 0, do: [:italic | a], else: a end)
    |> then(fn a -> if (attrs &&& @attr_reverse) != 0, do: [:reverse | a], else: a end)
    |> Enum.reverse()
  end

  # ── Highlight helpers ──

  @spec decode_spans(binary(), non_neg_integer(), [highlight_span()]) ::
          {:ok, [highlight_span()]} | :error
  defp decode_spans(_rest, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_spans(
         <<start_byte::32, end_byte::32, capture_id::16, rest::binary>>,
         remaining,
         acc
       ) do
    span = %{start_byte: start_byte, end_byte: end_byte, capture_id: capture_id}
    decode_spans(rest, remaining - 1, [span | acc])
  end

  defp decode_spans(_rest, _remaining, _acc), do: :error

  @spec decode_fold_ranges(binary(), non_neg_integer(), [
          {non_neg_integer(), non_neg_integer()}
        ]) ::
          {:ok, [{non_neg_integer(), non_neg_integer()}]} | :error
  defp decode_fold_ranges(_rest, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_fold_ranges(
         <<start_line::32, end_line::32, rest::binary>>,
         remaining,
         acc
       ) do
    decode_fold_ranges(rest, remaining - 1, [{start_line, end_line} | acc])
  end

  defp decode_fold_ranges(_rest, _remaining, _acc), do: :error

  @spec decode_names(binary(), non_neg_integer(), [String.t()]) :: {:ok, [String.t()]} | :error
  defp decode_names(_rest, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_names(<<name_len::16, name::binary-size(name_len), rest::binary>>, remaining, acc) do
    decode_names(rest, remaining - 1, [name | acc])
  end

  defp decode_names(_rest, _remaining, _acc), do: :error

  # ── Mouse helpers ──

  @spec decode_mouse_button(non_neg_integer()) :: mouse_button()
  # ── GUI action decoding ──

  @spec decode_gui_action(non_neg_integer(), binary()) :: {:ok, gui_action()} | :error
  defp decode_gui_action(@gui_action_select_tab, <<id::32>>), do: {:ok, {:select_tab, id}}
  defp decode_gui_action(@gui_action_close_tab, <<id::32>>), do: {:ok, {:close_tab, id}}

  defp decode_gui_action(@gui_action_file_tree_click, <<index::16>>),
    do: {:ok, {:file_tree_click, index}}

  defp decode_gui_action(@gui_action_file_tree_toggle, <<index::16>>),
    do: {:ok, {:file_tree_toggle, index}}

  defp decode_gui_action(@gui_action_completion_select, <<index::16>>),
    do: {:ok, {:completion_select, index}}

  defp decode_gui_action(@gui_action_breadcrumb_click, <<index::8>>),
    do: {:ok, {:breadcrumb_click, index}}

  defp decode_gui_action(@gui_action_toggle_panel, <<panel::8>>),
    do: {:ok, {:toggle_panel, panel}}

  defp decode_gui_action(@gui_action_new_tab, <<>>), do: {:ok, :new_tab}
  defp decode_gui_action(_, _), do: :error

  defp decode_mouse_button(@mouse_left), do: :left
  defp decode_mouse_button(@mouse_middle), do: :middle
  defp decode_mouse_button(@mouse_right), do: :right
  defp decode_mouse_button(@mouse_none), do: :none
  defp decode_mouse_button(@mouse_wheel_up), do: :wheel_up
  defp decode_mouse_button(@mouse_wheel_down), do: :wheel_down
  defp decode_mouse_button(@mouse_wheel_right), do: :wheel_right
  defp decode_mouse_button(@mouse_wheel_left), do: :wheel_left
  defp decode_mouse_button(other), do: {:unknown, other}

  @spec decode_mouse_event_type(non_neg_integer()) :: mouse_event_type()
  defp decode_mouse_event_type(@mouse_press), do: :press
  defp decode_mouse_event_type(@mouse_release), do: :release
  defp decode_mouse_event_type(@mouse_motion), do: :motion
  defp decode_mouse_event_type(@mouse_drag), do: :drag
  defp decode_mouse_event_type(other), do: {:unknown, other}

  # ── Log level helpers ──

  @spec decode_log_level(non_neg_integer()) :: String.t()
  defp decode_log_level(0), do: "ERR"
  defp decode_log_level(1), do: "WARN"
  defp decode_log_level(2), do: "INFO"
  defp decode_log_level(3), do: "DEBUG"
  defp decode_log_level(_), do: "UNKNOWN"

  @spec decode_injection_ranges(binary(), non_neg_integer(), [map()]) :: [map()]
  defp decode_injection_ranges(_rest, 0, acc), do: Enum.reverse(acc)

  defp decode_injection_ranges(
         <<start_byte::32, end_byte::32, name_len::16, name::binary-size(name_len),
           rest::binary>>,
         remaining,
         acc
       ) do
    range = %{start_byte: start_byte, end_byte: end_byte, language: name}
    decode_injection_ranges(rest, remaining - 1, [range | acc])
  end
end
