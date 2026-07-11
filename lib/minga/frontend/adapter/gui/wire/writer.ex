defmodule Minga.Frontend.Adapter.GUI.Wire.Writer do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Wire

  @enforce_keys [:command]
  defstruct command: nil, chunks: []

  @type t :: %__MODULE__{command: atom(), chunks: [iodata()]}

  @spec new(atom()) :: t()
  def new(command) when is_atom(command), do: %__MODULE__{command: command}

  @spec uint8(t(), atom(), term()) :: t()
  def uint8(%__MODULE__{} = writer, field, value) do
    append_uint(writer, field, value, Wire.max_u8(), 8)
  end

  @spec uint16(t(), atom(), term()) :: t()
  def uint16(%__MODULE__{} = writer, field, value) do
    append_uint(writer, field, value, Wire.max_u16(), 16)
  end

  @spec uint16(t(), atom(), term(), non_neg_integer()) :: t()
  def uint16(%__MODULE__{} = writer, field, value, max) do
    append_uint(writer, field, value, max, 16)
  end

  @spec uint32(t(), atom(), term()) :: t()
  def uint32(%__MODULE__{} = writer, field, value) do
    append_uint(writer, field, value, Wire.max_u32(), 32)
  end

  @spec uint64(t(), atom(), term()) :: t()
  def uint64(%__MODULE__{} = writer, field, value) do
    append_uint(writer, field, value, 18_446_744_073_709_551_615, 64)
  end

  @spec int32(t(), atom(), term()) :: t()
  def int32(%__MODULE__{} = writer, field, value) do
    Wire.validate_int!(writer.command, field, value, Wire.min_i32(), Wire.max_i32())
    append(writer, <<value::signed-32>>)
  end

  @spec uint24(t(), atom(), term()) :: t()
  def uint24(%__MODULE__{} = writer, field, value) do
    append_uint(writer, field, value, 16_777_215, 24)
  end

  @spec rgb24(t(), atom(), term()) :: t()
  def rgb24(%__MODULE__{} = writer, field, value), do: uint24(writer, field, value)

  @spec string8(t(), atom(), iodata()) :: t()
  def string8(%__MODULE__{} = writer, field, value) do
    append_string(writer, field, value, Wire.max_u8(), 8)
  end

  @spec string16(t(), atom(), iodata()) :: t()
  def string16(%__MODULE__{} = writer, field, value) do
    append_string(writer, field, value, Wire.max_u16(), 16)
  end

  @spec string32(t(), atom(), iodata()) :: t()
  def string32(%__MODULE__{} = writer, field, value) do
    append_payload(writer, field, value, Wire.max_u32(), 32)
  end

  @spec payload16(t(), atom(), iodata()) :: t()
  def payload16(%__MODULE__{} = writer, field, value) do
    append_payload(writer, field, value, Wire.max_u16(), 16)
  end

  @spec payload32(t(), atom(), iodata()) :: t()
  def payload32(%__MODULE__{} = writer, field, value) do
    append_payload(writer, field, value, Wire.max_u32(), 32)
  end

  @spec check_uint8(t(), atom(), term()) :: t()
  def check_uint8(%__MODULE__{} = writer, field, value) do
    check_uint(writer, field, value, Wire.max_u8())
  end

  @spec check_uint16(t(), atom(), term()) :: t()
  def check_uint16(%__MODULE__{} = writer, field, value) do
    check_uint(writer, field, value, Wire.max_u16())
  end

  @spec check_uint32(t(), atom(), term()) :: t()
  def check_uint32(%__MODULE__{} = writer, field, value) do
    check_uint(writer, field, value, Wire.max_u32())
  end

  @spec check_uint64(t(), atom(), term()) :: t()
  def check_uint64(%__MODULE__{} = writer, field, value) do
    check_uint(writer, field, value, 18_446_744_073_709_551_615)
  end

  @spec section16(t(), atom(), term(), iodata()) :: t()
  def section16(%__MODULE__{} = writer, field, section_id, payload) do
    writer
    |> uint8(:section_id, section_id)
    |> payload16(field, payload)
  end

  @spec append(t(), iodata()) :: t()
  def append(%__MODULE__{} = writer, chunk), do: %{writer | chunks: [chunk | writer.chunks]}

  @spec finish(t()) :: binary()
  def finish(%__MODULE__{} = writer), do: writer.chunks |> Enum.reverse() |> IO.iodata_to_binary()

  @spec append_uint(t(), atom(), term(), non_neg_integer(), 8 | 16 | 24 | 32 | 64) :: t()
  defp append_uint(%__MODULE__{} = writer, field, value, max, 8) do
    Wire.validate_uint!(writer.command, field, value, max)
    append(writer, <<value::8>>)
  end

  defp append_uint(%__MODULE__{} = writer, field, value, max, 16) do
    Wire.validate_uint!(writer.command, field, value, max)
    append(writer, <<value::16>>)
  end

  defp append_uint(%__MODULE__{} = writer, field, value, max, 32) do
    Wire.validate_uint!(writer.command, field, value, max)
    append(writer, <<value::32>>)
  end

  defp append_uint(%__MODULE__{} = writer, field, value, max, 24) do
    Wire.validate_uint!(writer.command, field, value, max)
    append(writer, <<value::24>>)
  end

  defp append_uint(%__MODULE__{} = writer, field, value, max, 64) do
    Wire.validate_uint!(writer.command, field, value, max)
    append(writer, <<value::64>>)
  end

  @spec append_string(t(), atom(), iodata(), non_neg_integer(), 8 | 16) :: t()
  defp append_string(%__MODULE__{} = writer, field, value, max, 8) do
    bytes = :erlang.iolist_to_binary([value])
    Wire.validate_uint!(writer.command, field, byte_size(bytes), max)
    append(writer, <<byte_size(bytes)::8, bytes::binary>>)
  end

  defp append_string(%__MODULE__{} = writer, field, value, max, 16) do
    bytes = :erlang.iolist_to_binary([value])
    Wire.validate_uint!(writer.command, field, byte_size(bytes), max)
    append(writer, <<byte_size(bytes)::16, bytes::binary>>)
  end

  defp append_payload(%__MODULE__{} = writer, field, value, max, 16) do
    bytes = :erlang.iolist_to_binary([value])
    Wire.validate_uint!(writer.command, field, byte_size(bytes), max)
    append(writer, <<byte_size(bytes)::16, bytes::binary>>)
  end

  defp append_payload(%__MODULE__{} = writer, field, value, max, 32) do
    bytes = :erlang.iolist_to_binary([value])
    Wire.validate_uint!(writer.command, field, byte_size(bytes), max)
    append(writer, <<byte_size(bytes)::32, bytes::binary>>)
  end

  defp check_uint(%__MODULE__{} = writer, field, value, max) do
    Wire.validate_uint!(writer.command, field, value, max)
    writer
  end
end
