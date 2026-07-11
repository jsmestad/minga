defmodule Minga.Frontend.Adapter.GUI.EncodingError do
  @moduledoc false

  @enforce_keys [:command, :field, :actual, :min, :max]
  defexception [:command, :field, :actual, :min, :max]

  @type t :: %__MODULE__{
          command: atom(),
          field: atom(),
          actual: term(),
          min: integer(),
          max: integer()
        }

  @impl Exception
  @spec message(t()) :: String.t()
  def message(%__MODULE__{} = error) do
    "cannot encode #{error.command}.#{error.field}=#{inspect(error.actual)}; expected #{error.min}..#{error.max}"
  end
end
