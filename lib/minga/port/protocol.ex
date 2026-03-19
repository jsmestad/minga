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
  | 0x1C   | draw_styled_text | `row::16, col::16, fg::24, bg::24, attrs::16, ul_color::24, blend::8, font_weight::8, text_len::16, text` |
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

  alias Minga.Port.Capabilities
  alias Minga.Port.Protocol.GUI, as: ProtocolGUI

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
  @op_draw_styled_text 0x1C

  # ── Font weight encoding (shared between set_font and draw_styled_text) ──

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

  # GUI chrome commands live in Protocol.GUI (contiguous range 0x70-0x78)

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
          | {:gui_action, ProtocolGUI.gui_action()}

  @typedoc "Cursor shape."
  @type cursor_shape :: :block | :beam | :underline

  @typedoc "A highlight span from tree-sitter."
  @type highlight_span :: %{
          start_byte: non_neg_integer(),
          end_byte: non_neg_integer(),
          capture_id: non_neg_integer(),
          pattern_index: non_neg_integer(),
          layer: non_neg_integer()
        }

  @typedoc "Text style attributes."
  @type style :: [
          {:fg, non_neg_integer()}
          | {:bg, non_neg_integer()}
          | {:bold, boolean()}
          | {:underline, boolean()}
          | {:italic, boolean()}
          | {:reverse, boolean()}
          | {:strikethrough, boolean()}
          | {:underline_style, :line | :curl | :dashed | :dotted | :double}
          | {:underline_color, non_neg_integer()}
          | {:blend, 0..100}
          | {:font_weight,
             :thin | :light | :regular | :medium | :semibold | :bold | :heavy | :black}
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

  @doc """
  Encodes a draw_styled_text command with extended attributes.

  Extended over `draw_text` with:
  - `attrs` expanded to 16 bits (adds strikethrough 0x10, underline_style 3 bits at 0xE0)
  - `underline_color` as a separate 24-bit RGB field (0x000000 = use fg)
  - `blend` as an 8-bit opacity value (0-100, 100 = fully opaque)
  - `font_weight` as an 8-bit weight index (0-7, maps to thin through black)

  Use this for text that needs underline styles, strikethrough, underline
  color, blend, or per-span font weight. For simple text
  (fg/bg/bold/italic/underline/reverse), `encode_draw/4` is more compact.
  """
  @spec encode_draw_styled(non_neg_integer(), non_neg_integer(), String.t(), style()) :: binary()
  def encode_draw_styled(row, col, text, style \\ [])
      when is_integer(row) and row >= 0 and is_integer(col) and col >= 0 and is_binary(text) do
    fg = Keyword.get(style, :fg, 0xFFFFFF)
    bg = Keyword.get(style, :bg, 0x000000)
    attrs = encode_attrs_extended(style)
    ul_color = Keyword.get(style, :underline_color, 0x000000)
    blend = Keyword.get(style, :blend, 100)
    font_weight = Map.get(@font_weight_map, Keyword.get(style, :font_weight, :regular), 2)
    text_len = byte_size(text)

    <<@op_draw_styled_text, row::16, col::16, fg::24, bg::24, attrs::16, ul_color::24, blend::8,
      font_weight::8, text_len::16, text::binary>>
  end

  @doc """
  Smart encoder: uses `draw_styled_text` if the style contains extended
  attributes, otherwise falls back to the more compact `draw_text`.
  """
  @spec encode_draw_smart(non_neg_integer(), non_neg_integer(), String.t(), style()) :: binary()
  def encode_draw_smart(row, col, text, style \\ []) do
    if needs_extended_encoding?(style) do
      encode_draw_styled(row, col, text, style)
    else
      encode_draw(row, col, text, style)
    end
  end

  @spec needs_extended_encoding?(style()) :: boolean()
  defp needs_extended_encoding?(style) do
    Keyword.has_key?(style, :strikethrough) ||
      Keyword.has_key?(style, :underline_style) ||
      Keyword.has_key?(style, :underline_color) ||
      Keyword.has_key?(style, :blend) ||
      Keyword.has_key?(style, :font_weight)
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
    case ProtocolGUI.decode_gui_action(action_type, rest) do
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
           | {:draw_styled_text, map()}
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

  def decode_command(
        <<@op_draw_styled_text, row::16, col::16, fg::24, bg::24, attrs::16, ul_color::24,
          blend::8, font_weight_byte::8, text_len::16, text::binary-size(text_len)>>
      ) do
    decoded_attrs = decode_attrs_extended(attrs)
    font_weight = Map.get(@font_weight_reverse, font_weight_byte, :regular)

    style =
      decoded_attrs
      |> then(fn a -> if ul_color != 0, do: [{:underline_color, ul_color} | a], else: a end)
      |> then(fn a -> if blend < 100, do: [{:blend, blend} | a], else: a end)
      |> then(fn a ->
        if font_weight != :regular, do: [{:font_weight, font_weight} | a], else: a
      end)

    {:ok, {:draw_styled_text, %{row: row, col: col, fg: fg, bg: bg, attrs: style, text: text}}}
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
  @attr_strikethrough 0x10
  # Underline style occupies bits 5-7 (3 bits) in extended attrs (u16)
  # 0b000 = line (default), 0b001 = curl, 0b010 = dashed, 0b011 = dotted, 0b100 = double
  @ul_style_shift 5

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

  @spec encode_attrs_extended(style()) :: non_neg_integer()
  defp encode_attrs_extended(style) do
    import Bitwise

    base = encode_attrs(style)

    base
    |> then(fn a ->
      if Keyword.get(style, :strikethrough, false), do: a ||| @attr_strikethrough, else: a
    end)
    |> then(fn a ->
      ul_style = Keyword.get(style, :underline_style, :line)
      a ||| ul_style_to_bits(ul_style) <<< @ul_style_shift
    end)
  end

  @spec ul_style_to_bits(atom()) :: non_neg_integer()
  defp ul_style_to_bits(:line), do: 0
  defp ul_style_to_bits(:curl), do: 1
  defp ul_style_to_bits(:dashed), do: 2
  defp ul_style_to_bits(:dotted), do: 3
  defp ul_style_to_bits(:double), do: 4
  defp ul_style_to_bits(_), do: 0

  @spec bits_to_ul_style(non_neg_integer()) :: atom()
  defp bits_to_ul_style(0), do: :line
  defp bits_to_ul_style(1), do: :curl
  defp bits_to_ul_style(2), do: :dashed
  defp bits_to_ul_style(3), do: :dotted
  defp bits_to_ul_style(4), do: :double
  defp bits_to_ul_style(_), do: :line

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

  @spec decode_attrs_extended(non_neg_integer()) :: keyword()
  defp decode_attrs_extended(attrs) do
    import Bitwise

    base = decode_attrs(Bitwise.band(attrs, 0x0F))

    base =
      if (attrs &&& @attr_strikethrough) != 0,
        do: [{:strikethrough, true} | base],
        else: base

    ul_bits = attrs >>> @ul_style_shift &&& 0x07

    if ul_bits != 0 do
      [{:underline_style, bits_to_ul_style(ul_bits)} | base]
    else
      base
    end
  end

  # ── Highlight helpers ──

  @spec decode_spans(binary(), non_neg_integer(), [highlight_span()]) ::
          {:ok, [highlight_span()]} | :error
  defp decode_spans(_rest, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_spans(
         <<start_byte::32, end_byte::32, capture_id::16, pattern_index::16, layer::16,
           rest::binary>>,
         remaining,
         acc
       ) do
    span = %{
      start_byte: start_byte,
      end_byte: end_byte,
      capture_id: capture_id,
      pattern_index: pattern_index,
      layer: layer
    }

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
