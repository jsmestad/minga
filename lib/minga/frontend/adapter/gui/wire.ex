defmodule Minga.Frontend.Adapter.GUI.Wire do
  @moduledoc false

  import Bitwise

  @max_u8 255
  @max_u16 65_535
  @max_u32 4_294_967_295
  @min_i32 -2_147_483_648
  @max_i32 2_147_483_647

  @type bounded_result :: {[binary()], non_neg_integer()}

  @spec max_u8() :: non_neg_integer()
  def max_u8, do: @max_u8

  @spec max_u16() :: non_neg_integer()
  def max_u16, do: @max_u16

  @spec max_u32() :: non_neg_integer()
  def max_u32, do: @max_u32

  @spec min_i32() :: integer()
  def min_i32, do: @min_i32

  @spec max_i32() :: integer()
  def max_i32, do: @max_i32

  @spec clamp_u8(term()) :: non_neg_integer()
  def clamp_u8(value) do
    validate_uint!(:gui_wire, :u8_value, value, @max_u8)
    value
  end

  @spec clamp_u16(term()) :: non_neg_integer()
  def clamp_u16(value) do
    validate_uint!(:gui_wire, :u16_value, value, @max_u16)
    value
  end

  @spec clamp_u32(term()) :: non_neg_integer()
  def clamp_u32(value) do
    validate_uint!(:gui_wire, :u32_value, value, @max_u32)
    value
  end

  @spec maybe_flag(non_neg_integer(), boolean(), non_neg_integer()) :: non_neg_integer()
  def maybe_flag(flags, true, bit), do: bor(flags, bsl(1, bit))
  def maybe_flag(flags, false, _bit), do: flags

  @spec encode_section(non_neg_integer(), iodata()) :: binary()
  def encode_section(section_id, payload) do
    payload = IO.iodata_to_binary(payload)
    validate_uint!(:gui_section, :section_id, section_id, @max_u8)
    validate_uint!(:gui_section, :payload_length, byte_size(payload), @max_u16)
    <<section_id::8, byte_size(payload)::16, payload::binary>>
  end

  @spec validate_uint!(atom(), atom(), integer(), non_neg_integer()) :: :ok
  def validate_uint!(_command, _field, value, max)
      when is_integer(value) and value >= 0 and value <= max, do: :ok

  def validate_uint!(command, field, value, max) do
    raise Minga.Frontend.Adapter.GUI.EncodingError,
      command: command,
      field: field,
      actual: value,
      min: 0,
      max: max
  end

  @spec validate_int!(atom(), atom(), term(), integer(), integer()) :: :ok
  def validate_int!(_command, _field, value, min, max)
      when is_integer(value) and value >= min and value <= max,
      do: :ok

  def validate_int!(command, field, value, min, max) do
    raise Minga.Frontend.Adapter.GUI.EncodingError,
      command: command,
      field: field,
      actual: value,
      min: min,
      max: max
  end

  @spec encode_string8(iodata()) :: binary()
  def encode_string8(value) do
    bytes = :erlang.iolist_to_binary([value])
    validate_uint!(:gui_string, :byte_length, byte_size(bytes), @max_u8)
    <<byte_size(bytes)::8, bytes::binary>>
  end

  @spec encode_string16(iodata()) :: binary()
  def encode_string16(value) do
    bytes = :erlang.iolist_to_binary([value])
    validate_uint!(:gui_string, :byte_length, byte_size(bytes), @max_u16)
    <<byte_size(bytes)::16, bytes::binary>>
  end

  @spec utf8_prefix_bytes(iodata(), non_neg_integer()) :: binary()
  def utf8_prefix_bytes(value, max_bytes) do
    bytes = :erlang.iolist_to_binary([value])
    validate_uint!(:gui_wire, :utf8_byte_length, byte_size(bytes), max_bytes)
    bytes
  end

  @spec bounded_entries([term()], (term() -> binary()), non_neg_integer(), non_neg_integer()) ::
          bounded_result()
  def bounded_entries(items, encode_fun, max_count, budget) do
    entries = Enum.map(items, encode_fun)
    validate_uint!(:gui_wire, :entry_count, Enum.count(entries), max_count)
    encoded_bytes = IO.iodata_length(entries)
    validate_uint!(:gui_wire, :entry_bytes, encoded_bytes, budget)
    {entries, budget - encoded_bytes}
  end

  @spec rgb(non_neg_integer()) :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def rgb(color) when is_integer(color) do
    {bsr(band(color, 0xFF0000), 16), bsr(band(color, 0x00FF00), 8), band(color, 0x0000FF)}
  end

  def rgb(_color), do: {0, 0, 0}

  @spec path_hash(String.t() | nil) :: non_neg_integer()
  def path_hash(nil), do: 0
  def path_hash(path) when is_binary(path), do: :erlang.phash2(path, @max_u32)
end
