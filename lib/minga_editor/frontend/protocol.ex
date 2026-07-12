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

  Rendering is semantic-first. GUI render commands are encoded by `Minga.Frontend.Adapter.GUI`, with this module retaining the common side-channel encoders for titles, fonts, window background, frame-transaction boundaries (`begin_frame`/`commit_frame`), and the `protocol_error` version-mismatch signal. The cell-paradigm encoders (`draw_text`, `set_cursor`, `clear`, region commands) were retired in protocol_version 2; `batch_end` was replaced by the begin/commit frame transaction in protocol_version 3 (#2219).

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
  @op_begin_frame Opcodes.begin_frame()
  @op_commit_frame Opcodes.commit_frame()
  @op_request_keyframe Opcodes.request_keyframe()
  @op_frame_applied Opcodes.frame_applied()
  @op_frame_rejected Opcodes.frame_rejected()
  @op_window_ref_miss Opcodes.window_ref_miss()
  @op_scroll_batch Opcodes.scroll_batch()
  @op_set_title Opcodes.set_title()
  @op_set_window_bg Opcodes.set_window_bg()
  @op_set_link_cursor Opcodes.set_link_cursor()
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
  back on `commit_frame`. `0` means "no correlation" (legacy frontends that omit it).
  """
  @type input_seq :: non_neg_integer()

  @typedoc "Stable frontend frame-transaction rejection reason."
  @type frame_rejection_reason ::
          :truncation
          | :commit_sequence_mismatch
          | :frame_sequence_not_increasing
          | :base_sequence_mismatch
          | :missing_theme
          | :incomplete_theme
          | :missing_window_reference
          | :window_epoch_mismatch
          | :invalid_retained_rows
          | :invalid_row_splice
          | :missing_font_resource
          | :transcript_desync
          | :decode_failure
          | :out_of_transaction_command
          | :resource_policy
          | :unknown

  @typedoc "Shared disposition for a rejected frontend frame."
  @type frame_rejection_disposition ::
          :retryable_recovery
          | :targeted_replacement
          | :adapted_retry
          | :terminal_frontend_failure

  @typedoc "An input event decoded from a frontend."
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
          | {:request_keyframe, last_good_frame_seq :: non_neg_integer(),
             generation :: non_neg_integer()}
          | {:frame_applied, generation :: non_neg_integer(), frame_seq :: non_neg_integer()}
          | {:frame_rejected, generation :: non_neg_integer(), frame_seq :: non_neg_integer(),
             last_applied_frame_seq :: non_neg_integer(), frame_rejection_reason(),
             frame_rejection_disposition()}
          | {:window_ref_miss, generation :: non_neg_integer(), frame_seq :: non_neg_integer(),
             last_applied_frame_seq :: non_neg_integer(), window_id :: non_neg_integer()}
          | {:scroll_batch, window_id :: non_neg_integer(), delta_lines :: integer(),
             direction :: :down | :up}

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

  @doc "Encodes a begin-frame command in the initial recovery generation."
  @spec encode_begin_frame(non_neg_integer(), non_neg_integer()) :: binary()
  def encode_begin_frame(frame_seq, base_frame_seq),
    do: encode_begin_frame(frame_seq, base_frame_seq, 1)

  @doc """
  Encodes a begin_frame command that opens a frame transaction (#2219).

  `frame_seq` is the strictly monotonic global frame sequence (reuses
  Renderer.Server's seq) used for resync/attach ordering. `base_frame_seq` names
  the frame this transaction's deltas assume; `base_frame_seq == 0` means keyframe
  (full snapshots, no deltas). Both fields are masked to u32 so a large monotonic
  `frame_seq` stays wire-safe. `generation` identifies the BEAM-owned recovery
  attempt. fixed:13 = opcode(1) + frame_seq(u32) + base(u32) + generation(u32).
  """
  @spec encode_begin_frame(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: binary()
  def encode_begin_frame(frame_seq, base_frame_seq, generation)
      when is_integer(frame_seq) and frame_seq >= 0 and is_integer(base_frame_seq) and
             base_frame_seq >= 0 and is_integer(generation) and generation >= 0 do
    <<@op_begin_frame, u32(frame_seq)::32, u32(base_frame_seq)::32, u32(generation)::32>>
  end

  @doc """
  Encodes a commit_frame command that closes a frame transaction (#2219).

  `frame_seq` must match the open begin_frame's `frame_seq`. `input_seq` is the
  echoed input correlation sequence (formerly carried by batch_end, ticket #2215):
  the frontend resolves a keystroke-to-write latency sample when the frame presents.
  `input_seq` defaults to `0` ("no correlation") and is a SEPARATE id from
  `frame_seq`. fixed:9 = opcode(1) + frame_seq(u32) + input_seq(u32).
  """
  @spec encode_commit_frame(non_neg_integer(), input_seq()) :: binary()
  def encode_commit_frame(frame_seq, input_seq \\ 0)
      when is_integer(frame_seq) and frame_seq >= 0 and is_integer(input_seq) and input_seq >= 0 do
    <<@op_commit_frame, u32(frame_seq)::32, u32(input_seq)::32>>
  end

  @spec u32(non_neg_integer()) :: non_neg_integer()
  defp u32(value), do: Bitwise.band(value, 0xFFFFFFFF)

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
  Encodes a set_link_cursor command (#2630).

  `active` toggles the GUI pointing-hand cursor while a Cmd/Ctrl+hover
  go-to-definition link preview is shown. The TUI sizes and skips it.
  """
  @spec encode_set_link_cursor(boolean()) :: binary()
  def encode_set_link_cursor(active) when is_boolean(active) do
    <<@op_set_link_cursor, if(active, do: 1, else: 0)::8>>
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
    count = Enum.count(families)

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

  @spec encode_edit_buffer(term(), term(), term()) :: term()
  def encode_edit_buffer(buffer_id, version, edits),
    do: Minga.Parser.Protocol.encode_edit_buffer(buffer_id, version, edits)

  @spec encode_set_language(term(), term()) :: term()
  def encode_set_language(buffer_id, name),
    do: Minga.Parser.Protocol.encode_set_language(buffer_id, name)

  @spec encode_parse_buffer(term(), term(), term()) :: term()
  def encode_parse_buffer(buffer_id, version, source),
    do: Minga.Parser.Protocol.encode_parse_buffer(buffer_id, version, source)

  @spec encode_set_highlight_query(term(), term()) :: term()
  def encode_set_highlight_query(buffer_id, query),
    do: Minga.Parser.Protocol.encode_set_highlight_query(buffer_id, query)

  @spec encode_set_injection_query(term(), term()) :: term()
  def encode_set_injection_query(buffer_id, query),
    do: Minga.Parser.Protocol.encode_set_injection_query(buffer_id, query)

  @spec encode_set_fold_query(term(), term()) :: term()
  def encode_set_fold_query(buffer_id, query),
    do: Minga.Parser.Protocol.encode_set_fold_query(buffer_id, query)

  @spec encode_set_indent_query(term(), term()) :: term()
  def encode_set_indent_query(buffer_id, query),
    do: Minga.Parser.Protocol.encode_set_indent_query(buffer_id, query)

  @spec encode_request_indent(term(), term(), term()) :: term()
  def encode_request_indent(buffer_id, request_id, line),
    do: Minga.Parser.Protocol.encode_request_indent(buffer_id, request_id, line)

  @spec encode_set_textobject_query(term(), term()) :: term()
  def encode_set_textobject_query(buffer_id, query),
    do: Minga.Parser.Protocol.encode_set_textobject_query(buffer_id, query)

  @spec encode_set_tags_query(term(), term()) :: term()
  def encode_set_tags_query(buffer_id, query),
    do: Minga.Parser.Protocol.encode_set_tags_query(buffer_id, query)

  @spec encode_request_textobject(term(), term(), term(), term(), term()) :: term()
  def encode_request_textobject(buffer_id, request_id, row, col, capture_name),
    do:
      Minga.Parser.Protocol.encode_request_textobject(
        buffer_id,
        request_id,
        row,
        col,
        capture_name
      )

  @spec encode_request_match_item(term(), term(), term(), term()) :: term()
  def encode_request_match_item(buffer_id, request_id, row, col),
    do: Minga.Parser.Protocol.encode_request_match_item(buffer_id, request_id, row, col)

  @spec encode_request_structural_nav(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          0..3
        ) :: binary()
  def encode_request_structural_nav(buffer_id, request_id, row, col, action),
    do:
      Minga.Parser.Protocol.encode_request_structural_nav(buffer_id, request_id, row, col, action)

  @spec encode_load_grammar(term(), term()) :: term()
  def encode_load_grammar(name, path), do: Minga.Parser.Protocol.encode_load_grammar(name, path)

  @spec encode_query_language_at(term(), term(), term()) :: term()
  def encode_query_language_at(buffer_id, request_id, byte_offset),
    do: Minga.Parser.Protocol.encode_query_language_at(buffer_id, request_id, byte_offset)

  @spec encode_close_buffer(term()) :: term()
  def encode_close_buffer(buffer_id), do: Minga.Parser.Protocol.encode_close_buffer(buffer_id)

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
        <<@op_ready, width::16, height::16, caps_version::8, caps_len::8,
          caps_data::binary-size(caps_len), protocol_version::16>>
      ) do
    caps = Capabilities.from_binary(caps_data, caps_version)
    {:ok, {:ready, width, height, caps, protocol_version}}
  end

  # Extended ready with capabilities, no version tail (legacy frontend): opcode(1)
  # + width(2) + height(2) + caps_version(1) + caps_len(1) + caps_data. Surfaced
  # as protocol_version 0 ("unversioned") so the Manager can reject it explicitly.
  def decode_event(
        <<@op_ready, width::16, height::16, caps_version::8, caps_len::8,
          caps_data::binary-size(caps_len)>>
      ) do
    caps = Capabilities.from_binary(caps_data, caps_version)
    {:ok, {:ready, width, height, caps, 0}}
  end

  # Short ready (backward compat with old frontends).
  def decode_event(<<@op_ready, width::16, height::16>>) do
    {:ok, {:ready, width, height}}
  end

  # Capabilities updated event (sent after async capability detection).
  def decode_event(
        <<@op_capabilities_updated, caps_version::8, caps_len::8,
          caps_data::binary-size(caps_len)>>
      ) do
    caps = Capabilities.from_binary(caps_data, caps_version)
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

  # Generation-aware frame status (#2739). All values are fixed-width so malformed
  # statuses fail closed in the generic decoder rather than partially advancing state.
  def decode_event(<<@op_request_keyframe, last_good_frame_seq::32, generation::32>>) do
    {:ok, {:request_keyframe, last_good_frame_seq, generation}}
  end

  def decode_event(<<@op_frame_applied, generation::32, frame_seq::32>>) do
    {:ok, {:frame_applied, generation, frame_seq}}
  end

  def decode_event(
        <<@op_frame_rejected, generation::32, frame_seq::32, last_applied::32, reason::8,
          disposition::8>>
      ) do
    {:ok,
     {:frame_rejected, generation, frame_seq, last_applied, decode_rejection_reason(reason),
      decode_rejection_disposition(disposition)}}
  end

  # Compatibility for a protocol-version-11 status already draining on reconnect.
  def decode_event(
        <<@op_frame_rejected, generation::32, frame_seq::32, last_applied::32, reason::8>>
      ) do
    {:ok,
     {:frame_rejected, generation, frame_seq, last_applied, decode_rejection_reason(reason),
      :retryable_recovery}}
  end

  def decode_event(
        <<@op_window_ref_miss, generation::32, frame_seq::32, last_applied::32, window_id::16>>
      ) do
    {:ok, {:window_ref_miss, generation, frame_seq, last_applied, window_id}}
  end

  def decode_event(<<@op_scroll_batch, window_id::16, delta_lines::16-signed, direction::8>>) do
    dir = if direction == 0, do: :down, else: :up
    {:ok, {:scroll_batch, window_id, delta_lines, dir}}
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
             @op_capabilities_updated,
             @op_request_keyframe,
             @op_frame_applied,
             @op_frame_rejected,
             @op_window_ref_miss,
             @op_scroll_batch
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

  @spec decode_rejection_reason(non_neg_integer()) :: frame_rejection_reason()
  defp decode_rejection_reason(1), do: :truncation
  defp decode_rejection_reason(2), do: :commit_sequence_mismatch
  defp decode_rejection_reason(3), do: :frame_sequence_not_increasing
  defp decode_rejection_reason(4), do: :base_sequence_mismatch
  defp decode_rejection_reason(5), do: :missing_theme
  defp decode_rejection_reason(6), do: :incomplete_theme
  defp decode_rejection_reason(7), do: :missing_window_reference
  defp decode_rejection_reason(8), do: :window_epoch_mismatch
  defp decode_rejection_reason(9), do: :invalid_retained_rows
  defp decode_rejection_reason(10), do: :missing_font_resource
  defp decode_rejection_reason(11), do: :transcript_desync
  defp decode_rejection_reason(12), do: :decode_failure
  defp decode_rejection_reason(13), do: :out_of_transaction_command
  defp decode_rejection_reason(14), do: :invalid_row_splice
  defp decode_rejection_reason(15), do: :resource_policy
  defp decode_rejection_reason(_), do: :unknown

  @spec decode_rejection_disposition(non_neg_integer()) :: frame_rejection_disposition()
  defp decode_rejection_disposition(1), do: :retryable_recovery
  defp decode_rejection_disposition(2), do: :targeted_replacement
  defp decode_rejection_disposition(3), do: :adapted_retry
  defp decode_rejection_disposition(4), do: :terminal_frontend_failure
  defp decode_rejection_disposition(_), do: :terminal_frontend_failure

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
