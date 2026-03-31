defmodule ChangesetFs.Protocol do
  @moduledoc """
  Binary protocol for BEAM ↔ FSKit communication.

  Messages are length-prefixed: 4 bytes big-endian length, then payload.
  Payload starts with a 1-byte opcode, followed by opcode-specific fields.

  All strings are length-prefixed: 2 bytes big-endian length, then UTF-8 bytes.

  ## Request opcodes (FSKit → BEAM)

  | Opcode | Name    | Payload                        |
  |--------|---------|--------------------------------|
  | 0x01   | LOOKUP  | parent_path, name              |
  | 0x02   | READ    | path, offset::32, count::32    |
  | 0x03   | READDIR | path                           |
  | 0x04   | GETATTR | path                           |
  | 0x05   | WRITE   | path, offset::32, data         |
  | 0x06   | CREATE  | parent_path, name, type::8     |
  | 0x07   | REMOVE  | parent_path, name              |

  ## Response opcodes (BEAM → FSKit)

  | Opcode | Name            | Payload                                  |
  |--------|-----------------|------------------------------------------|
  | 0x81   | OK_ITEM         | type::8, size::64, path                  |
  | 0x82   | OK_DATA         | data_len::32, data                       |
  | 0x83   | OK_ENTRIES      | count::16, [name, type::8, size::64]...  |
  | 0x84   | OK_ATTR         | type::8, size::64, mtime::64, mode::32   |
  | 0x85   | OK              | (empty)                                  |
  | 0xFF   | ERROR           | code::8, message                         |

  ## Type codes

  | Code | Type      |
  |------|-----------|
  | 0x01 | file      |
  | 0x02 | directory |
  | 0x03 | symlink   |
  """

  # Request opcodes
  @op_lookup 0x01
  @op_read 0x02
  @op_readdir 0x03
  @op_getattr 0x04
  @op_write 0x05
  @op_create 0x06
  @op_remove 0x07

  # Response opcodes
  @op_ok_item 0x81
  @op_ok_data 0x82
  @op_ok_entries 0x83
  @op_ok_attr 0x84
  @op_ok 0x85
  @op_error 0xFF

  # Type codes
  @type_file 0x01
  @type_dir 0x02

  # Error codes
  @err_not_found 0x01
  @err_io 0x02
  @err_exists 0x03
  @err_deleted 0x04

  # ── Encoding requests ──────────────────────────────────────────────

  @spec encode_lookup(String.t(), String.t()) :: binary()
  def encode_lookup(parent_path, name) do
    <<@op_lookup, encode_string(parent_path)::binary, encode_string(name)::binary>>
  end

  @spec encode_read(String.t(), non_neg_integer(), non_neg_integer()) :: binary()
  def encode_read(path, offset, count) do
    <<@op_read, encode_string(path)::binary, offset::32, count::32>>
  end

  @spec encode_readdir(String.t()) :: binary()
  def encode_readdir(path) do
    <<@op_readdir, encode_string(path)::binary>>
  end

  @spec encode_getattr(String.t()) :: binary()
  def encode_getattr(path) do
    <<@op_getattr, encode_string(path)::binary>>
  end

  @spec encode_write(String.t(), non_neg_integer(), binary()) :: binary()
  def encode_write(path, offset, data) do
    <<@op_write, encode_string(path)::binary, offset::32,
      byte_size(data)::32, data::binary>>
  end

  # ── Encoding responses ─────────────────────────────────────────────

  @spec encode_ok_item(:file | :directory, non_neg_integer(), String.t()) :: binary()
  def encode_ok_item(type, size, path) do
    type_byte = type_to_byte(type)
    <<@op_ok_item, type_byte, size::64, encode_string(path)::binary>>
  end

  @spec encode_ok_data(binary()) :: binary()
  def encode_ok_data(data) do
    <<@op_ok_data, byte_size(data)::32, data::binary>>
  end

  @spec encode_ok_entries([{String.t(), :file | :directory, non_neg_integer()}]) :: binary()
  def encode_ok_entries(entries) do
    count = length(entries)

    entries_bin =
      Enum.map(entries, fn {name, type, size} ->
        <<encode_string(name)::binary, type_to_byte(type), size::64>>
      end)
      |> IO.iodata_to_binary()

    <<@op_ok_entries, count::16, entries_bin::binary>>
  end

  @spec encode_ok_attr(:file | :directory, non_neg_integer(), non_neg_integer(), non_neg_integer()) :: binary()
  def encode_ok_attr(type, size, mtime, mode) do
    <<@op_ok_attr, type_to_byte(type), size::64, mtime::64, mode::32>>
  end

  @spec encode_ok() :: binary()
  def encode_ok do
    <<@op_ok>>
  end

  @spec encode_error(:not_found | :io | :exists | :deleted, String.t()) :: binary()
  def encode_error(code, message) do
    code_byte = error_to_byte(code)
    <<@op_error, code_byte, encode_string(message)::binary>>
  end

  # ── Decoding ───────────────────────────────────────────────────────

  @spec decode_request(binary()) :: {:ok, term()} | {:error, :unknown_opcode}
  def decode_request(<<@op_lookup, rest::binary>>) do
    {parent, rest} = decode_string(rest)
    {name, _} = decode_string(rest)
    {:ok, {:lookup, parent, name}}
  end

  def decode_request(<<@op_read, rest::binary>>) do
    {path, rest} = decode_string(rest)
    <<offset::32, count::32>> = rest
    {:ok, {:read, path, offset, count}}
  end

  def decode_request(<<@op_readdir, rest::binary>>) do
    {path, _} = decode_string(rest)
    {:ok, {:readdir, path}}
  end

  def decode_request(<<@op_getattr, rest::binary>>) do
    {path, _} = decode_string(rest)
    {:ok, {:getattr, path}}
  end

  def decode_request(<<@op_write, rest::binary>>) do
    {path, rest} = decode_string(rest)
    <<offset::32, data_len::32, data::binary-size(data_len)>> = rest
    {:ok, {:write, path, offset, data}}
  end

  def decode_request(<<@op_create, rest::binary>>) do
    {parent, rest} = decode_string(rest)
    {name, <<type_byte>>} = decode_string(rest)
    {:ok, {:create, parent, name, byte_to_type(type_byte)}}
  end

  def decode_request(<<@op_remove, rest::binary>>) do
    {parent, rest} = decode_string(rest)
    {name, _} = decode_string(rest)
    {:ok, {:remove, parent, name}}
  end

  def decode_request(_), do: {:error, :unknown_opcode}

  @spec decode_response(binary()) :: {:ok, term()} | {:error, term()}
  def decode_response(<<@op_ok_item, type_byte, size::64, rest::binary>>) do
    {path, _} = decode_string(rest)
    {:ok, {:item, byte_to_type(type_byte), size, path}}
  end

  def decode_response(<<@op_ok_data, data_len::32, data::binary-size(data_len)>>) do
    {:ok, {:data, data}}
  end

  def decode_response(<<@op_ok_entries, count::16, rest::binary>>) do
    entries = decode_entries(rest, count, [])
    {:ok, {:entries, entries}}
  end

  def decode_response(<<@op_ok_attr, type_byte, size::64, mtime::64, mode::32>>) do
    {:ok, {:attr, byte_to_type(type_byte), size, mtime, mode}}
  end

  def decode_response(<<@op_ok>>) do
    {:ok, :ok}
  end

  def decode_response(<<@op_error, code_byte, rest::binary>>) do
    {message, _} = decode_string(rest)
    {:error, {byte_to_error(code_byte), message}}
  end

  # ── Frame reading from socket ──────────────────────────────────────

  @spec read_frame(:gen_tcp.socket()) :: {:ok, binary()} | {:error, term()}
  def read_frame(socket) do
    with {:ok, <<length::32>>} <- :gen_tcp.recv(socket, 4),
         {:ok, data} <- :gen_tcp.recv(socket, length) do
      {:ok, data}
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp encode_string(s) do
    <<byte_size(s)::16, s::binary>>
  end

  defp decode_string(<<len::16, s::binary-size(len), rest::binary>>) do
    {s, rest}
  end

  defp decode_entries(_rest, 0, acc), do: Enum.reverse(acc)

  defp decode_entries(rest, count, acc) do
    {name, rest} = decode_string(rest)
    <<type_byte, size::64, rest::binary>> = rest
    entry = {name, byte_to_type(type_byte), size}
    decode_entries(rest, count - 1, [entry | acc])
  end

  defp type_to_byte(:file), do: @type_file
  defp type_to_byte(:directory), do: @type_dir

  defp byte_to_type(@type_file), do: :file
  defp byte_to_type(@type_dir), do: :directory

  defp error_to_byte(:not_found), do: @err_not_found
  defp error_to_byte(:io), do: @err_io
  defp error_to_byte(:exists), do: @err_exists
  defp error_to_byte(:deleted), do: @err_deleted

  defp byte_to_error(@err_not_found), do: :not_found
  defp byte_to_error(@err_io), do: :io
  defp byte_to_error(@err_exists), do: :exists
  defp byte_to_error(@err_deleted), do: :deleted
end
