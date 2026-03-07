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

  # Highlight commands (BEAM → Zig)
  @op_set_language 0x20
  @op_parse_buffer 0x21
  @op_set_highlight_query 0x22
  @op_load_grammar 0x23
  @op_set_injection_query 0x24
  @op_query_language_at 0x25

  # Highlight responses (Zig → BEAM)
  @op_highlight_spans 0x30
  @op_highlight_names 0x31
  @op_grammar_loaded 0x32
  @op_language_at_response 0x33
  @op_injection_ranges 0x34
  @op_text_width 0x35

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
          | {:mouse_event, row :: integer(), col :: integer(), mouse_button(), modifiers(),
             mouse_event_type()}
          | {:highlight_spans, version :: non_neg_integer(), [highlight_span()]}
          | {:highlight_names, [String.t()]}
          | {:grammar_loaded, success :: boolean(), name :: String.t()}
          | {:injection_ranges,
             [%{start_byte: non_neg_integer(), end_byte: non_neg_integer(), language: String.t()}]}
          | {:language_at_response, request_id :: non_neg_integer(), language :: String.t()}
          | {:text_width, request_id :: non_neg_integer(), width :: non_neg_integer()}
          | {:log_message, level :: String.t(), text :: String.t()}

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

  @doc "Encodes a set_window_bg command to set the window chrome background color."
  @spec encode_set_window_bg(non_neg_integer()) :: binary()
  def encode_set_window_bg(rgb) when is_integer(rgb) do
    r = Bitwise.band(Bitwise.bsr(rgb, 16), 0xFF)
    g = Bitwise.band(Bitwise.bsr(rgb, 8), 0xFF)
    b = Bitwise.band(rgb, 0xFF)
    <<@op_set_window_bg, r::8, g::8, b::8>>
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
  Encodes an edit_buffer command with a version and a list of edit deltas.

  Each delta describes a replacement: the range [start_byte, old_end_byte) is
  replaced with `inserted_text`, producing a range [start_byte, new_end_byte).
  """
  @spec encode_edit_buffer(non_neg_integer(), [edit_delta()]) :: binary()
  def encode_edit_buffer(version, edits) when is_integer(version) and is_list(edits) do
    header = <<@op_edit_buffer, version::32, length(edits)::16>>

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

  @doc "Encodes a set_language command."
  @spec encode_set_language(String.t()) :: binary()
  def encode_set_language(name) when is_binary(name) do
    <<@op_set_language, byte_size(name)::16, name::binary>>
  end

  @doc "Encodes a parse_buffer command with a version counter."
  @spec encode_parse_buffer(non_neg_integer(), String.t()) :: binary()
  def encode_parse_buffer(version, source)
      when is_integer(version) and version >= 0 and is_binary(source) do
    <<@op_parse_buffer, version::32, byte_size(source)::32, source::binary>>
  end

  @doc "Encodes a set_highlight_query command."
  @spec encode_set_highlight_query(String.t()) :: binary()
  def encode_set_highlight_query(query) when is_binary(query) do
    <<@op_set_highlight_query, byte_size(query)::32, query::binary>>
  end

  @doc "Encodes a set_injection_query command."
  @spec encode_set_injection_query(String.t()) :: binary()
  def encode_set_injection_query(query) when is_binary(query) do
    <<@op_set_injection_query, byte_size(query)::32, query::binary>>
  end

  @doc "Encodes a load_grammar command."
  @spec encode_load_grammar(String.t(), String.t()) :: binary()
  def encode_load_grammar(name, path) when is_binary(name) and is_binary(path) do
    <<@op_load_grammar, byte_size(name)::16, name::binary, byte_size(path)::16, path::binary>>
  end

  @doc "Encodes a query_language_at request: request_id(4) + byte_offset(4)."
  @spec encode_query_language_at(non_neg_integer(), non_neg_integer()) :: binary()
  def encode_query_language_at(request_id, byte_offset)
      when is_integer(request_id) and is_integer(byte_offset) do
    <<@op_query_language_at, request_id::32, byte_offset::32>>
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

  def decode_event(
        <<@op_mouse_event, row::16-signed, col::16-signed, button::8, mods::8, event_type::8>>
      ) do
    {:ok,
     {:mouse_event, row, col, decode_mouse_button(button), mods,
      decode_mouse_event_type(event_type)}}
  end

  def decode_event(<<@op_highlight_spans, version::32, count::32, rest::binary>>) do
    case decode_spans(rest, count, []) do
      {:ok, spans} -> {:ok, {:highlight_spans, version, spans}}
      :error -> {:error, :malformed}
    end
  end

  def decode_event(<<@op_highlight_names, count::16, rest::binary>>) do
    case decode_names(rest, count, []) do
      {:ok, names} -> {:ok, {:highlight_names, names}}
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

  def decode_event(<<@op_injection_ranges, count::16, rest::binary>>) do
    {:ok, {:injection_ranges, decode_injection_ranges(rest, count, [])}}
  end

  def decode_event(<<@op_text_width, request_id::32, width::16>>) do
    {:ok, {:text_width, request_id, width}}
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

  def decode_command(<<_opcode::8, _rest::binary>>) do
    {:error, :unknown_opcode}
  end

  def decode_command(<<>>) do
    {:error, :malformed}
  end

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
