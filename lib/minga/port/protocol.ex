defmodule Minga.Port.Protocol do
  @moduledoc """
  Binary protocol encoder/decoder for BEAM ↔ Zig communication.

  Messages are length-prefixed binaries (4-byte big-endian header,
  handled by Erlang's `{:packet, 4}` Port option). The payload
  starts with a 1-byte opcode followed by opcode-specific fields.

  ## Input Events (Zig → BEAM)

  | Opcode | Name      | Payload                              |
  |--------|-----------|--------------------------------------|
  | 0x01   | key_press | `codepoint::32, modifiers::8`        |
  | 0x02   | resize    | `width::16, height::16`              |
  | 0x03   | ready     | `width::16, height::16`              |

  ## Render Commands (BEAM → Zig)

  | Opcode | Name       | Payload                                                              |
  |--------|------------|----------------------------------------------------------------------|
  | 0x10   | draw_text  | `row::16, col::16, fg::24, bg::24, attrs::8, text_len::16, text`     |
  | 0x11   | set_cursor | `row::16, col::16`                                                   |
  | 0x12   | clear      | (empty)                                                              |
  | 0x13   | batch_end  | (empty)                                                              |

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

  # Render commands (BEAM → Zig)
  @op_draw_text 0x10
  @op_set_cursor 0x11
  @op_clear 0x12
  @op_batch_end 0x13

  # ── Modifier flags ──

  @mod_shift 0x01
  @mod_ctrl 0x02
  @mod_alt 0x04
  @mod_super 0x08

  # ── Types ──

  @typedoc "Modifier flag bitmask."
  @type modifiers :: non_neg_integer()

  @typedoc "An input event decoded from Zig."
  @type input_event ::
          {:key_press, codepoint :: non_neg_integer(), modifiers()}
          | {:resize, width :: pos_integer(), height :: pos_integer()}
          | {:ready, width :: pos_integer(), height :: pos_integer()}

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

  # ── Decoding (Zig → BEAM) ──

  @doc "Decodes an input event from a binary payload."
  @spec decode_event(binary()) :: {:ok, input_event()} | {:error, :unknown_opcode | :malformed}
  def decode_event(<<@op_key_press, codepoint::32, modifiers::8>>) do
    {:ok, {:key_press, codepoint, modifiers}}
  end

  def decode_event(<<@op_resize, width::16, height::16>>) do
    {:ok, {:resize, width, height}}
  end

  def decode_event(<<@op_ready, width::16, height::16>>) do
    {:ok, {:ready, width, height}}
  end

  def decode_event(<<opcode::8, _rest::binary>>)
      when opcode in [@op_key_press, @op_resize, @op_ready] do
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
           | {:set_cursor, non_neg_integer(), non_neg_integer()}}
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
end
