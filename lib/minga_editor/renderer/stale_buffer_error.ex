defmodule MingaEditor.Renderer.StaleBufferError do
  @moduledoc false

  @enforce_keys [:buffer, :expected_version]
  defexception [:buffer, :expected_version]

  @type t :: %__MODULE__{
          buffer: pid(),
          expected_version: non_neg_integer()
        }

  @impl Exception
  @spec message(t()) :: String.t()
  def message(%__MODULE__{} = error) do
    "buffer #{inspect(error.buffer)} advanced past renderer version #{error.expected_version}"
  end
end
