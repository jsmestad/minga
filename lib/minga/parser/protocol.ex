defmodule Minga.Parser.Protocol do
  @moduledoc """
  Binary protocol encoding/decoding for the tree-sitter parser Port.

  The parser Port (minga-parser) speaks the same wire format as the
  frontend Port (minga-renderer). This module owns the parser-specific
  opcodes and encode/decode functions. `MingaEditor.Frontend.Protocol`
  delegates parser functions here so existing Layer 2 callers work
  unchanged.

  This is a Layer 0 module. It has no dependencies on MingaEditor.*.
  """

  alias Minga.Language.Highlight.InjectionRange
  alias Minga.Language.Highlight.Span
  alias Minga.Language.Symbol
  alias Minga.Parser.StructuralNavResult

  alias Minga.Protocol.Opcodes

  @op_log_message Opcodes.log_message()
  @op_set_language Opcodes.set_language()
  @op_parse_buffer Opcodes.parse_buffer()
  @op_set_highlight_query Opcodes.set_highlight_query()
  @op_load_grammar Opcodes.load_grammar()
  @op_set_injection_query Opcodes.set_injection_query()
  @op_query_language_at Opcodes.query_language_at()
  @op_edit_buffer Opcodes.edit_buffer()
  @op_set_fold_query Opcodes.set_fold_query()
  @op_set_indent_query Opcodes.set_indent_query()
  @op_request_indent Opcodes.request_indent()
  @op_set_textobject_query Opcodes.set_textobject_query()
  @op_request_textobject Opcodes.request_textobject()
  @op_close_buffer Opcodes.close_buffer()
  @op_request_match_item Opcodes.request_match_item()
  @op_request_structural_nav Opcodes.request_structural_nav()
  @op_set_tags_query Opcodes.set_tags_query()
  @op_highlight_spans Opcodes.highlight_spans()
  @op_highlight_names Opcodes.highlight_names()
  @op_grammar_loaded Opcodes.grammar_loaded()
  @op_language_at_response Opcodes.language_at_response()
  @op_injection_ranges Opcodes.injection_ranges()
  @op_fold_ranges Opcodes.fold_ranges()
  @op_indent_result Opcodes.indent_result()
  @op_textobject_result Opcodes.textobject_result()
  @op_textobject_positions Opcodes.textobject_positions()
  @op_conceal_spans Opcodes.conceal_spans()
  @op_request_reparse Opcodes.request_reparse()
  @op_match_item_result Opcodes.match_item_result()
  @op_node_info Opcodes.node_info()
  @op_document_symbols Opcodes.document_symbols()

  # Well-known textobject type IDs (match Zig constants)
  @textobj_function 0
  @textobj_class 1
  @textobj_parameter 2
  @textobj_block 3
  @textobj_comment 4
  @textobj_test 5

  # Well-known document symbol kind IDs (match Zig constants)
  @symbol_function 0
  @symbol_module 1
  @symbol_method 2
  @symbol_interface 3
  @symbol_test 4

  # ── Encoding: incremental content sync (BEAM → Zig) ──

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

  @doc "Encodes a set_tags_query command with buffer_id."
  @spec encode_set_tags_query(non_neg_integer(), String.t()) :: binary()
  def encode_set_tags_query(buffer_id, query)
      when is_integer(buffer_id) and buffer_id >= 0 and is_binary(query) do
    <<@op_set_tags_query, buffer_id::32, byte_size(query)::32, query::binary>>
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

  @doc "Encodes a request_match_item command: buffer_id(4) + request_id(4) + row(4) + col(4)."
  @spec encode_request_match_item(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: binary()
  def encode_request_match_item(buffer_id, request_id, row, col)
      when is_integer(buffer_id) and buffer_id >= 0 and
             is_integer(request_id) and is_integer(row) and is_integer(col) do
    <<@op_request_match_item, buffer_id::32, request_id::32, row::32, col::32>>
  end

  @doc "Encodes a request_structural_nav command: buffer_id(4) + request_id(4) + row(4) + col(4) + action(1)."
  @spec encode_request_structural_nav(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          0..3
        ) :: binary()
  def encode_request_structural_nav(buffer_id, request_id, row, col, action)
      when is_integer(buffer_id) and buffer_id >= 0 and
             is_integer(request_id) and is_integer(row) and is_integer(col) and
             is_integer(action) and action >= 0 and action <= 3 do
    <<@op_request_structural_nav, buffer_id::32, request_id::32, row::32, col::32, action::8>>
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

  # ── Decoding: parser events (Zig → BEAM) ──

  @doc """
  Decodes a parser event from a binary payload.

  Returns `{:ok, event}` for recognized parser opcodes, `:unknown` for
  unrecognized opcodes (which may be input events handled by
  `MingaEditor.Frontend.Protocol`), or `{:error, :malformed}` for
  truncated data.
  """
  @spec decode_event(binary()) :: {:ok, term()} | :unknown | {:error, :malformed}

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

  def decode_event(<<@op_match_item_result, request_id::32, 1, row::32, col::32>>) do
    {:ok, {:match_item_result, request_id, {row, col}}}
  end

  def decode_event(<<@op_match_item_result, request_id::32, 0>>) do
    {:ok, {:match_item_result, request_id, nil}}
  end

  def decode_event(
        <<@op_node_info, request_id::32, 1, start_row::32, start_col::32, end_row::32,
          end_col::32, type_len::16, type_name::binary-size(type_len)>>
      ) do
    result = StructuralNavResult.new(start_row, start_col, end_row, end_col, type_name)
    {:ok, {:node_info, request_id, result}}
  end

  def decode_event(<<@op_node_info, request_id::32, 0>>) do
    {:ok, {:node_info, request_id, nil}}
  end

  def decode_event(
        <<@op_textobject_positions, buffer_id::32, version::32, count::32, entries::binary>>
      ) do
    positions = decode_textobject_entries(entries, count, %{})
    {:ok, {:textobject_positions, buffer_id, version, positions}}
  end

  def decode_event(<<@op_conceal_spans, buffer_id::32, version::32, count::32, rest::binary>>) do
    case decode_conceal_spans(rest, count, []) do
      {:ok, spans} -> {:ok, {:conceal_spans, buffer_id, version, spans}}
      :error -> {:error, :malformed}
    end
  end

  def decode_event(<<@op_request_reparse, buffer_id::32>>) do
    {:ok, {:request_reparse, buffer_id}}
  end

  def decode_event(<<@op_document_symbols, buffer_id::32, version::32, count::32, rest::binary>>) do
    case decode_document_symbols(rest, count, []) do
      {:ok, symbols} -> {:ok, {:document_symbols, buffer_id, version, symbols}}
      :error -> {:error, :malformed}
    end
  end

  def decode_event(<<@op_log_message, level_byte::8, msg_len::16, msg::binary-size(msg_len)>>) do
    level = decode_log_level(level_byte)
    {:ok, {:log_message, level, msg}}
  end

  def decode_event(_binary) do
    :unknown
  end

  # ── Private decode helpers ──

  @spec decode_spans(binary(), non_neg_integer(), [Span.t()]) :: {:ok, [Span.t()]} | :error
  defp decode_spans(_rest, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_spans(
         <<start_byte::32, end_byte::32, capture_id::16, pattern_index::16, layer::16,
           rest::binary>>,
         remaining,
         acc
       ) do
    span = %Span{
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

  @typedoc "A conceal span from tree-sitter: byte range + replacement text."
  @type conceal_span :: %{
          start_byte: non_neg_integer(),
          end_byte: non_neg_integer(),
          replacement: String.t()
        }

  @spec decode_conceal_spans(binary(), non_neg_integer(), [conceal_span()]) ::
          {:ok, [conceal_span()]} | :error
  defp decode_conceal_spans(_rest, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_conceal_spans(
         <<start_byte::32, end_byte::32, rep_len::16, rep::binary-size(rep_len), rest::binary>>,
         remaining,
         acc
       )
       when remaining > 0 do
    span = %{start_byte: start_byte, end_byte: end_byte, replacement: rep}
    decode_conceal_spans(rest, remaining - 1, [span | acc])
  end

  defp decode_conceal_spans(_rest, _remaining, _acc), do: :error

  @spec decode_document_symbols(binary(), non_neg_integer(), [Symbol.t()]) ::
          {:ok, [Symbol.t()]} | :error
  defp decode_document_symbols(_data, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_document_symbols(
         <<kind_id::8, name_len::16, name::binary-size(name_len), start_row::32, start_col::32,
           end_row::32, end_col::32, rest::binary>>,
         remaining,
         acc
       ) do
    symbol = %Symbol{
      kind: symbol_kind_to_atom(kind_id),
      name: name,
      range: {start_row, start_col, end_row, end_col}
    }

    decode_document_symbols(rest, remaining - 1, [symbol | acc])
  end

  defp decode_document_symbols(_data, _remaining, _acc), do: :error

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

  @spec decode_injection_ranges(binary(), non_neg_integer(), [InjectionRange.t()]) ::
          [InjectionRange.t()]
  defp decode_injection_ranges(_rest, 0, acc), do: Enum.reverse(acc)

  defp decode_injection_ranges(
         <<start_byte::32, end_byte::32, name_len::16, name::binary-size(name_len),
           rest::binary>>,
         remaining,
         acc
       ) do
    range = %InjectionRange{
      start_byte: start_byte,
      end_byte: end_byte,
      language: name
    }

    decode_injection_ranges(rest, remaining - 1, [range | acc])
  end

  @spec symbol_kind_to_atom(non_neg_integer()) :: Symbol.kind()
  defp symbol_kind_to_atom(@symbol_function), do: :function
  defp symbol_kind_to_atom(@symbol_module), do: :module
  defp symbol_kind_to_atom(@symbol_method), do: :method
  defp symbol_kind_to_atom(@symbol_interface), do: :interface
  defp symbol_kind_to_atom(@symbol_test), do: :test
  defp symbol_kind_to_atom(_), do: :function

  @spec textobj_type_to_atom(non_neg_integer()) :: atom()
  defp textobj_type_to_atom(@textobj_function), do: :function
  defp textobj_type_to_atom(@textobj_class), do: :class
  defp textobj_type_to_atom(@textobj_parameter), do: :parameter
  defp textobj_type_to_atom(@textobj_block), do: :block
  defp textobj_type_to_atom(@textobj_comment), do: :comment
  defp textobj_type_to_atom(@textobj_test), do: :test
  defp textobj_type_to_atom(_), do: :unknown

  @spec decode_log_level(non_neg_integer()) :: String.t()
  defp decode_log_level(0), do: "ERR"
  defp decode_log_level(1), do: "WARN"
  defp decode_log_level(2), do: "INFO"
  defp decode_log_level(3), do: "DEBUG"
  defp decode_log_level(_), do: "UNKNOWN"
end
