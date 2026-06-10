defmodule MingaEditor.Frontend.Protocol do
  @moduledoc """
  Binary protocol encoder/decoder for BEAM ↔ frontend communication.

  Messages are length-prefixed binaries (4-byte big-endian header,
  handled by Erlang's `{:packet, 4}` Port option). The payload
  starts with a 1-byte opcode followed by opcode-specific fields.

  ## Input Events (frontend → BEAM)

  | Opcode | Name        | Payload                                                     |
  |--------|-------------|-------------------------------------------------------------|
  | 0x01   | key_press   | `codepoint::32, modifiers::8[, seq::32]`                    |
  | 0x02   | resize      | `width::16, height::16`                                     |
  | 0x03   | ready       | `width::16, height::16[, caps..., protocol_version::16]`    |
  | 0x04   | mouse_event | `row::16-signed, col::16-signed, button::8, mods::8, type::8` |

  The extended `ready` handshake carries the frontend's compiled-in
  `protocol_version`; the BEAM rejects a mismatch with `protocol_error` (0x18).

  ## Render Commands (BEAM → frontend)

  Rendering is semantic-first. GUI render commands are encoded by `Minga.Frontend.Adapter.GUI`, with this module retaining the common side-channel encoders for titles, fonts, window background, batch boundaries, and the `protocol_error` version-mismatch signal. The cell-paradigm encoders (`draw_text`, `set_cursor`, `clear`, region commands) were retired in protocol_version 2.

  ## Modifier Flags

  | Flag  | Value |
  |-------|-------|
  | SHIFT | 0x01  |
  | CTRL  | 0x02  |
  | ALT   | 0x04  |
  | SUPER | 0x08  |
  """

  alias Minga.Protocol.Opcodes

  @op_key_press Opcodes.key_press()
  @op_resize Opcodes.resize()
  @op_ready Opcodes.ready()
  @op_mouse_event Opcodes.mouse_event()
  @op_capabilities_updated Opcodes.capabilities_updated()
  @op_paste_event Opcodes.paste_event()
  @op_gui_action Opcodes.gui_action()
  @op_protocol_error Opcodes.protocol_error()
  @op_batch_end Opcodes.batch_end()
  @op_set_title Opcodes.set_title()
  @op_set_window_bg Opcodes.set_window_bg()
  @op_set_font Opcodes.set_font()
  @op_set_font_fallback Opcodes.set_font_fallback()
  @op_register_font Opcodes.register_font()

  alias Minga.Parser.StructuralNavResult
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

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

  # GUI chrome commands live in Protocol.GUI (contiguous range 0x70-0x78)

  # Parser protocol opcodes are defined in Minga.Parser.Protocol.
  # Encode/decode functions for parser commands are delegated there.

  # Log message opcode is defined in Minga.Parser.Protocol (0x60)

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

  @typedoc """
  A frontend-originated input correlation sequence (u32).

  Stamped by the frontend at input decode for end-to-end keystroke latency
  instrumentation (ticket #2215). The BEAM echoes the latest processed sequence
  back on `batch_end`. `0` means "no correlation" (legacy frontends that omit it).
  """
  @type input_seq :: non_neg_integer()

  @typedoc "An input event decoded from Zig."
  @type input_event ::
          {:key_press, codepoint :: non_neg_integer(), modifiers(), input_seq()}
          | {:resize, width :: pos_integer(), height :: pos_integer()}
          | {:ready, width :: pos_integer(), height :: pos_integer()}
          | {:ready, width :: pos_integer(), height :: pos_integer(), Capabilities.t(),
             protocol_version :: non_neg_integer()}
          | {:capabilities_updated, Capabilities.t()}
          | {:paste_event, text :: String.t()}
          | {:mouse_event, row :: integer(), col :: integer(), mouse_button(), modifiers(),
             mouse_event_type(), click_count :: pos_integer()}
          | {:highlight_spans, buffer_id :: non_neg_integer(), version :: non_neg_integer(),
             [highlight_span()]}
          | {:highlight_names, buffer_id :: non_neg_integer(), [String.t()]}
          | {:conceal_spans, buffer_id :: non_neg_integer(), version :: non_neg_integer(),
             [conceal_span()]}
          | {:grammar_loaded, success :: boolean(), name :: String.t()}
          | {:injection_ranges, buffer_id :: non_neg_integer(),
             [Minga.Language.Highlight.InjectionRange.t()]}
          | {:language_at_response, request_id :: non_neg_integer(), language :: String.t()}
          | {:fold_ranges, buffer_id :: non_neg_integer(), version :: non_neg_integer(),
             [{start_line :: non_neg_integer(), end_line :: non_neg_integer()}]}
          | {:indent_result, request_id :: non_neg_integer(), line :: non_neg_integer(),
             indent_level :: integer()}
          | {:textobject_result, request_id :: non_neg_integer(),
             result ::
               {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
               | nil}
          | {:node_info, request_id :: non_neg_integer(), StructuralNavResult.t() | nil}
          | {:match_item_result, request_id :: non_neg_integer(),
             result :: {non_neg_integer(), non_neg_integer()} | nil}
          | {:textobject_positions, buffer_id :: non_neg_integer(), version :: non_neg_integer(),
             %{atom() => [{non_neg_integer(), non_neg_integer()}]}}
          | {:request_reparse, buffer_id :: non_neg_integer()}
          | {:log_message, level :: String.t(), text :: String.t()}
          | {:gui_action, ProtocolGUI.gui_action()}

  @typedoc "Cursor shape."
  @type cursor_shape :: :block | :beam | :underline

  @typedoc "A highlight span from tree-sitter."
  @type highlight_span :: Minga.Language.Highlight.Span.t()

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

  # ── Encoding (BEAM → frontend) ──

  @doc """
  Encodes a protocol_error command.

  The BEAM emits this when a frontend's handshake `protocol_version` does not
  match the BEAM's compiled-in `Opcodes.protocol_version()`. The frontend
  displays the UTF-8 reason as a blocking error instead of trying to decode a
  command stream it cannot parse. len16-framed: opcode(1) + len(u16) + message.
  """
  @spec encode_protocol_error(String.t()) :: binary()
  def encode_protocol_error(message) when is_binary(message) do
    <<@op_protocol_error, byte_size(message)::16, message::binary>>
  end

  @doc """
  Encodes a batch_end command (triggers render flush).

  Carries the echoed input correlation sequence (u32) so the frontend can
  resolve a keystroke-to-write latency sample when the frame reaches the
  terminal (ticket #2215). `seq` defaults to `0` ("no correlation").
  """
  @spec encode_batch_end(input_seq()) :: binary()
  def encode_batch_end(seq \\ 0) when is_integer(seq) and seq >= 0 do
    <<@op_batch_end, seq::32>>
  end

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

  @doc """
  Encodes a set_font_fallback command to configure the GUI's font fallback chain.

  The fallback chain is tried in order when the primary font (set via `set_font`)
  doesn't have a glyph. Each entry is a font family name resolved by the frontend
  via NSFontManager. After the configured fallbacks, the system fallback
  (CTFontCreateForString) is used as a last resort.

  Format: `opcode:8, count:8, [name_len:16, name:bytes]*`
  """
  @spec encode_set_font_fallback([String.t()]) :: binary()
  def encode_set_font_fallback(families) when is_list(families) do
    count = length(families)

    entries =
      Enum.map(families, fn name ->
        <<byte_size(name)::16, name::binary>>
      end)

    IO.iodata_to_binary([@op_set_font_fallback, count | entries])
  end

  @doc """
  Encodes a register_font command to associate a font_id with a font family.

  Font ID 0 is the primary font (set via `set_font`). IDs 1-255 are
  secondary fonts that can be referenced by `font_id` in `draw_styled_text`.
  The GUI creates a FontFace for each registered font at the same size as
  the primary. If the secondary font's cell metrics differ from the primary,
  the GUI logs a warning and falls back to the primary for those glyphs.

  Format: `opcode:8, font_id:8, name_len:16, name:bytes`
  """
  @spec encode_register_font(non_neg_integer(), String.t()) :: binary()
  def encode_register_font(font_id, family)
      when is_integer(font_id) and font_id >= 0 and font_id <= 255 and is_binary(family) do
    <<@op_register_font, font_id::8, byte_size(family)::16, family::binary>>
  end

  # ── Parser protocol (delegated to Minga.Parser.Protocol) ──

  @type edit_delta :: Minga.Parser.Protocol.edit_delta()

  defdelegate encode_edit_buffer(buffer_id, version, edits), to: Minga.Parser.Protocol
  defdelegate encode_set_language(buffer_id, name), to: Minga.Parser.Protocol
  defdelegate encode_parse_buffer(buffer_id, version, source), to: Minga.Parser.Protocol
  defdelegate encode_set_highlight_query(buffer_id, query), to: Minga.Parser.Protocol
  defdelegate encode_set_injection_query(buffer_id, query), to: Minga.Parser.Protocol
  defdelegate encode_set_fold_query(buffer_id, query), to: Minga.Parser.Protocol
  defdelegate encode_set_indent_query(buffer_id, query), to: Minga.Parser.Protocol
  defdelegate encode_request_indent(buffer_id, request_id, line), to: Minga.Parser.Protocol
  defdelegate encode_set_textobject_query(buffer_id, query), to: Minga.Parser.Protocol
  defdelegate encode_set_tags_query(buffer_id, query), to: Minga.Parser.Protocol

  defdelegate encode_request_textobject(buffer_id, request_id, row, col, capture_name),
    to: Minga.Parser.Protocol

  defdelegate encode_request_match_item(buffer_id, request_id, row, col),
    to: Minga.Parser.Protocol

  @spec encode_request_structural_nav(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          0..3
        ) :: binary()
  defdelegate encode_request_structural_nav(buffer_id, request_id, row, col, action),
    to: Minga.Parser.Protocol

  defdelegate encode_load_grammar(name, path), to: Minga.Parser.Protocol

  defdelegate encode_query_language_at(buffer_id, request_id, byte_offset),
    to: Minga.Parser.Protocol

  defdelegate encode_close_buffer(buffer_id), to: Minga.Parser.Protocol

  # ── Decoding (Zig → BEAM) ──

  @doc "Decodes an input event from a binary payload."
  @spec decode_event(binary()) :: {:ok, input_event()} | {:error, :unknown_opcode | :malformed}
  # New form carries a u32 input correlation sequence (ticket #2215) appended
  # after modifiers so latency samples can be resolved at the frame boundary.
  def decode_event(<<@op_key_press, codepoint::32, modifiers::8, seq::32>>) do
    {:ok, {:key_press, codepoint, modifiers, seq}}
  end

  # Legacy form without a sequence; treat as uncorrelated (seq 0).
  def decode_event(<<@op_key_press, codepoint::32, modifiers::8>>) do
    {:ok, {:key_press, codepoint, modifiers, 0}}
  end

  def decode_event(<<@op_resize, width::16, height::16>>) do
    {:ok, {:resize, width, height}}
  end

  # Versioned ready: extended ready followed by a u16 protocol_version tail
  # (protocol_version 2+). The frontend stamps the wire-contract version it was
  # generated against so the BEAM can reject a mismatch before streaming frames.
  def decode_event(
        <<@op_ready, width::16, height::16, _caps_version::8, caps_len::8,
          caps_data::binary-size(caps_len), protocol_version::16>>
      ) do
    caps = Capabilities.from_binary(caps_data)
    {:ok, {:ready, width, height, caps, protocol_version}}
  end

  # Extended ready with capabilities, no version tail (legacy frontend): opcode(1)
  # + width(2) + height(2) + caps_version(1) + caps_len(1) + caps_data. Surfaced
  # as protocol_version 0 ("unversioned") so the Manager can reject it explicitly.
  def decode_event(
        <<@op_ready, width::16, height::16, _caps_version::8, caps_len::8,
          caps_data::binary-size(caps_len)>>
      ) do
    caps = Capabilities.from_binary(caps_data)
    {:ok, {:ready, width, height, caps, 0}}
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

  # Parser events are decoded by Minga.Parser.Protocol. Try it first,
  # then fall through to input event decoders.
  def decode_event(<<opcode::8, _rest::binary>> = data)
      when opcode in 0x30..0x3E or opcode == 0x60 do
    case Minga.Parser.Protocol.decode_event(data) do
      {:ok, _} = result -> result
      :unknown -> {:error, :unknown_opcode}
      {:error, _} = err -> err
    end
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

  @type conceal_span :: Minga.Parser.Protocol.conceal_span()

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
end
