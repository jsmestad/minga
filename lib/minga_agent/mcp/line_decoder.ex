defmodule MingaAgent.MCP.LineDecoder do
  @moduledoc """
  Bounded incremental decoder for one JSON-lines frame.

  An Erlang port opened with `{:line, n}` splits a long line into `{:noeol, piece}` messages followed by one `{:eol, tail}` message. The decoder keeps the pieces as reversed iodata, so each push is O(1) and retains the piece by reference instead of copying the bytes received so far. `finish/2` converts the frame to a binary once, so building a frame of `n` bytes copies each byte once.

  The decoder counts every byte it retains, including the tail. When a frame would exceed `max_bytes`, the decoder returns `{:error, {:line_too_long, byte_count}}` and retains nothing, so retained incomplete-frame bytes never exceed `max_bytes`.
  """

  @enforce_keys [:max_bytes]
  defstruct [:max_bytes, pieces: [], bytes: 0]

  @typedoc "Error returned when a frame would exceed the configured byte limit."
  @type overflow :: {:line_too_long, pos_integer()}

  @typedoc "Decoder state for the frame that is being received."
  @type t :: %__MODULE__{
          max_bytes: pos_integer(),
          pieces: [binary()],
          bytes: non_neg_integer()
        }

  @doc "Returns an empty decoder that accepts frames up to `max_bytes` bytes."
  @spec new(pos_integer()) :: t()
  def new(max_bytes) when is_integer(max_bytes) and max_bytes > 0,
    do: %__MODULE__{max_bytes: max_bytes}

  @doc "Accepts one piece of a frame that has not ended yet."
  @spec push(t(), binary()) :: {:ok, t()} | {:error, overflow()}
  def push(%__MODULE__{} = decoder, piece) when is_binary(piece) do
    with {:ok, bytes} <- admit(decoder, piece) do
      {:ok, %{decoder | pieces: [piece | decoder.pieces], bytes: bytes}}
    end
  end

  @doc "Accepts the last piece of a frame and returns the frame with an empty decoder."
  @spec finish(t(), binary()) :: {:ok, binary(), t()} | {:error, overflow()}
  def finish(%__MODULE__{} = decoder, tail) when is_binary(tail) do
    with {:ok, _bytes} <- admit(decoder, tail) do
      frame = IO.iodata_to_binary(:lists.reverse([tail | decoder.pieces]))
      {:ok, frame, reset(decoder)}
    end
  end

  @doc "Discards the frame that is being received and keeps the byte limit."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{max_bytes: max_bytes}), do: new(max_bytes)

  @doc "Returns the number of bytes retained for the frame that is being received."
  @spec buffered_bytes(t()) :: non_neg_integer()
  def buffered_bytes(%__MODULE__{bytes: bytes}), do: bytes

  @spec admit(t(), binary()) :: {:ok, non_neg_integer()} | {:error, overflow()}
  defp admit(%__MODULE__{bytes: bytes, max_bytes: max_bytes}, piece) do
    case bytes + byte_size(piece) do
      total when total > max_bytes -> {:error, {:line_too_long, total}}
      total -> {:ok, total}
    end
  end
end
