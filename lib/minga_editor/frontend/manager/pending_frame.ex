defmodule MingaEditor.Frontend.Manager.PendingFrame do
  @moduledoc "Immutable encoded frame retained while frontend transport admission is unwritable."

  alias Minga.Protocol.Opcodes
  alias MingaEditor.Frontend.FrameTransaction

  @begin_frame Opcodes.begin_frame()

  @enforce_keys [:batch, :frame_seq, :base_frame_seq, :generation]
  defstruct [:batch, :frame_seq, :base_frame_seq, :generation]

  @type t :: %__MODULE__{
          batch: binary(),
          frame_seq: non_neg_integer(),
          base_frame_seq: non_neg_integer(),
          generation: non_neg_integer()
        }

  @doc "Builds retained frame metadata from one complete encoded transaction."
  @spec from_commands([binary()]) :: {:ok, t()} | {:error, FrameTransaction.validation_error()}
  def from_commands(commands) when is_list(commands) do
    with :ok <- FrameTransaction.validate(commands),
         {:ok, frame_seq, base_frame_seq, generation} <- transaction_header(commands) do
      {:ok,
       %__MODULE__{
         batch: IO.iodata_to_binary(commands),
         frame_seq: frame_seq,
         base_frame_seq: base_frame_seq,
         generation: generation
       }}
    end
  end

  @doc "Returns retained encoded bytes."
  @spec byte_size(t()) :: non_neg_integer()
  def byte_size(%__MODULE__{batch: batch}), do: Kernel.byte_size(batch)

  @doc "Returns whether this frame can follow an admitted predecessor without a missing base."
  @spec follows?(t(), t()) :: boolean()
  def follows?(%__MODULE__{base_frame_seq: 0}, %__MODULE__{}), do: true

  def follows?(%__MODULE__{base_frame_seq: base}, %__MODULE__{frame_seq: frame_seq}),
    do: base == frame_seq

  @spec transaction_header([binary()]) ::
          {:ok, non_neg_integer(), non_neg_integer(), non_neg_integer()}
          | {:error, FrameTransaction.validation_error()}
  defp transaction_header([
         <<@begin_frame, frame_seq::32, base_frame_seq::32, generation::32>> | _commands
       ]),
       do: {:ok, frame_seq, base_frame_seq, generation}

  defp transaction_header(_commands), do: {:error, :malformed_command}
end
