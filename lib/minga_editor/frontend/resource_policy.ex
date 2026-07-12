defmodule MingaEditor.Frontend.ResourcePolicy do
  @moduledoc """
  Versioned frontend hard-dimension policy advertised during capability negotiation.

  Zero-valued dimensions are unadvertised. Limits describe admission boundaries
  only; payload-derived usage stays local to the producer and privacy-safe telemetry.
  """

  @type dimension :: :frame_bytes | :frame_commands | :window_rows
  @type adaptation_descriptor :: %{
          required(:dimension) => dimension(),
          required(:rejected_value) => pos_integer(),
          required(:adapted_value) => pos_integer()
        }

  @enforce_keys [:version, :max_frame_bytes, :max_frame_commands, :max_window_rows]
  defstruct [:version, :max_frame_bytes, :max_frame_commands, :max_window_rows]

  @type t :: %__MODULE__{
          version: non_neg_integer(),
          max_frame_bytes: non_neg_integer(),
          max_frame_commands: non_neg_integer(),
          max_window_rows: non_neg_integer()
        }

  @doc "Returns the legacy policy with no advertised hard dimensions."
  @spec unadvertised() :: t()
  def unadvertised do
    %__MODULE__{
      version: 0,
      max_frame_bytes: 0,
      max_frame_commands: 0,
      max_window_rows: 0
    }
  end

  @doc "Builds the version-one resource policy appended by capability format 2."
  @spec new(non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: t()
  def new(version, max_frame_bytes, max_frame_commands, max_window_rows)
      when version >= 0 and max_frame_bytes >= 0 and max_frame_commands >= 0 and
             max_window_rows >= 0 do
    %__MODULE__{
      version: version,
      max_frame_bytes: max_frame_bytes,
      max_frame_commands: max_frame_commands,
      max_window_rows: max_window_rows
    }
  end

  @doc "Validates an explicit adapted-retry descriptor for one named bounded dimension."
  @spec adaptation(dimension(), integer(), integer()) :: {:ok, adaptation_descriptor()} | :error
  def adaptation(dimension, rejected_value, adapted_value)
      when dimension in [:frame_bytes, :frame_commands, :window_rows] and rejected_value > 0 and
             adapted_value > 0 and rejected_value != adapted_value do
    {:ok, %{dimension: dimension, rejected_value: rejected_value, adapted_value: adapted_value}}
  end

  def adaptation(_dimension, _rejected_value, _adapted_value), do: :error

  @doc "Returns whether a frontend advertises a hard limit for the named dimension."
  @spec advertised?(t(), dimension()) :: boolean()
  def advertised?(%__MODULE__{version: version, max_frame_bytes: limit}, :frame_bytes),
    do: version > 0 and limit > 0

  def advertised?(%__MODULE__{version: version, max_frame_commands: limit}, :frame_commands),
    do: version > 0 and limit > 0

  def advertised?(%__MODULE__{version: version, max_window_rows: limit}, :window_rows),
    do: version > 0 and limit > 0
end
