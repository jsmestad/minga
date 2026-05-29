defmodule Minga.Frontend.Adapter.GUI.Wire do
  @moduledoc false

  import Bitwise

  @max_u8 255
  @max_u16 65_535
  @max_u32 4_294_967_295

  @type bounded_result :: {[binary()], non_neg_integer()}

  @spec max_u8() :: non_neg_integer()
  def max_u8, do: @max_u8

  @spec max_u16() :: non_neg_integer()
  def max_u16, do: @max_u16

  @spec max_u32() :: non_neg_integer()
  def max_u32, do: @max_u32

  @spec clamp_u8(term()) :: non_neg_integer()
  def clamp_u8(value) when is_integer(value), do: value |> max(0) |> min(@max_u8)
  def clamp_u8(_value), do: 0

  @spec clamp_u16(term()) :: non_neg_integer()
  def clamp_u16(value) when is_integer(value), do: value |> max(0) |> min(@max_u16)
  def clamp_u16(_value), do: 0

  @spec clamp_u32(term()) :: non_neg_integer()
  def clamp_u32(value) when is_integer(value), do: value |> max(0) |> min(@max_u32)
  def clamp_u32(_value), do: 0

  @spec maybe_flag(non_neg_integer(), boolean(), non_neg_integer()) :: non_neg_integer()
  def maybe_flag(flags, true, bit), do: bor(flags, bsl(1, bit))
  def maybe_flag(flags, false, _bit), do: flags

  @spec encode_section(non_neg_integer(), iodata()) :: binary()
  def encode_section(section_id, payload) do
    payload = IO.iodata_to_binary(payload)
    <<section_id::8, byte_size(payload)::16, payload::binary>>
  end

  @spec encode_string8(iodata()) :: binary()
  def encode_string8(value) do
    bytes = :erlang.iolist_to_binary([value])
    <<byte_size(bytes)::8, bytes::binary>>
  end

  @spec encode_string16(iodata()) :: binary()
  def encode_string16(value) do
    bytes = :erlang.iolist_to_binary([value])
    <<byte_size(bytes)::16, bytes::binary>>
  end

  @spec utf8_prefix_bytes(iodata(), non_neg_integer()) :: binary()
  def utf8_prefix_bytes(value, max_bytes) do
    value
    |> :erlang.iolist_to_binary()
    |> do_utf8_prefix_bytes(max_bytes, "")
  end

  @spec bounded_entries([term()], (term() -> binary()), non_neg_integer(), non_neg_integer()) ::
          bounded_result()
  def bounded_entries(items, encode_fun, max_count, budget) do
    {entries, remaining_budget, _count} =
      Enum.reduce_while(items, {[], budget, 0}, fn item, acc ->
        item |> encode_fun.() |> maybe_add_bounded_entry(acc, max_count)
      end)

    {Enum.reverse(entries), remaining_budget}
  end

  @spec rgb(non_neg_integer()) :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def rgb(color) when is_integer(color) do
    {bsr(band(color, 0xFF0000), 16), bsr(band(color, 0x00FF00), 8), band(color, 0x0000FF)}
  end

  def rgb(_color), do: {0, 0, 0}

  @spec path_hash(String.t() | nil) :: non_neg_integer()
  def path_hash(nil), do: 0
  def path_hash(path) when is_binary(path), do: :erlang.phash2(path, @max_u32)

  @spec maybe_add_bounded_entry(
          binary(),
          {[binary()], non_neg_integer(), non_neg_integer()},
          non_neg_integer()
        ) ::
          {:cont, {[binary()], non_neg_integer(), non_neg_integer()}}
          | {:halt, {[binary()], non_neg_integer(), non_neg_integer()}}
  defp maybe_add_bounded_entry(_entry, acc = {_entries, _budget, count}, max_count)
       when count >= max_count do
    {:halt, acc}
  end

  defp maybe_add_bounded_entry(entry, {entries, budget, count}, _max_count)
       when byte_size(entry) <= budget do
    {:cont, {[entry | entries], budget - byte_size(entry), count + 1}}
  end

  defp maybe_add_bounded_entry(_entry, acc, _max_count), do: {:halt, acc}

  @spec do_utf8_prefix_bytes(binary(), non_neg_integer(), binary()) :: binary()
  defp do_utf8_prefix_bytes(_binary, max_bytes, acc) when byte_size(acc) >= max_bytes, do: acc
  defp do_utf8_prefix_bytes(<<>>, _max_bytes, acc), do: acc

  defp do_utf8_prefix_bytes(<<char::utf8, rest::binary>>, max_bytes, acc) do
    char_bytes = <<char::utf8>>

    if byte_size(acc) + byte_size(char_bytes) <= max_bytes do
      do_utf8_prefix_bytes(rest, max_bytes, acc <> char_bytes)
    else
      acc
    end
  end

  defp do_utf8_prefix_bytes(_invalid, _max_bytes, acc), do: acc
end
