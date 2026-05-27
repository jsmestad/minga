defmodule Minga.Frontend.Protocol.Encoding do
  @moduledoc false

  @truncation_suffix "\n… [truncated]"

  # ── Section encoding ─────────────────────────────────────────────────────

  @doc """
  Encodes a section with its ID and length-prefixed payload.

  Wire format: `<<section_id::8, byte_size(payload)::16, payload::binary>>`
  """
  @spec encode_section(non_neg_integer(), binary()) :: binary()
  def encode_section(section_id, payload) do
    <<section_id::8, byte_size(payload)::16, payload::binary>>
  end

  # ── String encoding ──────────────────────────────────────────────────────

  @doc """
  Length-prefixed string with a 16-bit byte-length header.

  Wire format: `<<byte_size(str)::16, str::binary>>`
  """
  @spec encode_string16(String.t()) :: binary()
  def encode_string16(value) do
    bytes = :erlang.iolist_to_binary([value])
    <<byte_size(bytes)::16, bytes::binary>>
  end

  # ── UTF-8 truncation ─────────────────────────────────────────────────────

  @doc """
  Returns a binary truncated to at most `max_bytes` while preserving valid
  UTF-8. Appends a truncation suffix when the string is longer than the limit
  (and the limit is large enough to include the suffix).
  """
  @spec utf8_prefix_bytes(String.t(), non_neg_integer()) :: binary()
  def utf8_prefix_bytes(text, max_bytes) when byte_size(text) <= max_bytes do
    if String.valid?(text) do
      :erlang.iolist_to_binary([text])
    else
      valid_utf8_prefix(text, max_bytes)
    end
  end

  def utf8_prefix_bytes(text, max_bytes) do
    suffix_bytes = :erlang.iolist_to_binary([@truncation_suffix])

    if max_bytes <= byte_size(suffix_bytes) do
      valid_utf8_prefix(text, max_bytes)
    else
      valid_utf8_prefix(text, max_bytes - byte_size(suffix_bytes)) <> suffix_bytes
    end
  end

  # ── Boolean encoding ─────────────────────────────────────────────────────

  @doc """
  Converts a boolean to a single byte: `true -> 1`, `false -> 0`, `nil -> 0`.
  """
  @spec bool_to_byte(boolean() | nil) :: 0 | 1
  def bool_to_byte(true), do: 1
  def bool_to_byte(false), do: 0
  def bool_to_byte(nil), do: 0

  # ── Internal helpers ─────────────────────────────────────────────────────

  @spec valid_utf8_prefix(String.t(), non_neg_integer()) :: binary()
  defp valid_utf8_prefix(_text, 0), do: ""

  defp valid_utf8_prefix(text, max_bytes) do
    text
    |> binary_part(0, min(max_bytes, byte_size(text)))
    |> trim_invalid_utf8_suffix()
  end

  @spec trim_invalid_utf8_suffix(binary()) :: binary()
  defp trim_invalid_utf8_suffix(<<>>), do: ""

  defp trim_invalid_utf8_suffix(prefix) do
    if String.valid?(prefix) do
      prefix
    else
      prefix |> binary_part(0, byte_size(prefix) - 1) |> trim_invalid_utf8_suffix()
    end
  end
end
