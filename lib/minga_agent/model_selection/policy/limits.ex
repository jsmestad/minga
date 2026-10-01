defmodule MingaAgent.ModelSelection.Policy.Limits do
  @moduledoc "Advertised model limits and the finite selected request output limit."
  @enforce_keys [:context, :input, :output, :request_output]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          context: pos_integer() | nil,
          input: pos_integer() | nil,
          output: pos_integer() | nil,
          request_output: pos_integer()
        }

  defguardp optional_positive(value) when is_nil(value) or (is_integer(value) and value > 0)

  @doc "Validates optional advertised limits and a required positive request limit."
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_limits}
  def new(%{context: context, input: input, output: output, request_output: request})
      when optional_positive(context) and optional_positive(input) and optional_positive(output) and
             is_integer(request) and request > 0 do
    {:ok, %__MODULE__{context: context, input: input, output: output, request_output: request}}
  end

  def new(_attrs), do: {:error, :invalid_limits}
end
