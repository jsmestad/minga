defmodule Minga.Protocol.EncodingError do
  @moduledoc """
  Raised when a protocol value cannot fit its schema-owned wire field.

  `field_path` follows the schema from the encoded command root. Array indexes
  are zero-based so callers can identify the exact failing element.
  """

  @enforce_keys [:command, :field_path, :actual, :min, :max]
  defexception [:command, :field, :field_path, :actual, :min, :max]

  @type path_segment :: atom() | non_neg_integer()
  @type t :: %__MODULE__{
          command: atom(),
          field: atom() | nil,
          field_path: [path_segment()],
          actual: term(),
          min: integer(),
          max: non_neg_integer()
        }

  @impl Exception
  @spec message(t()) :: String.t()
  def message(%__MODULE__{} = error) do
    path = Enum.map_join(error.field_path, ".", &to_string/1)

    "cannot encode #{error.command}.#{path}=#{inspect(error.actual)}; " <>
      "expected #{error.min}..#{error.max}"
  end
end
