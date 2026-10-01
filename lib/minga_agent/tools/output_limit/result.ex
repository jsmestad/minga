defmodule MingaAgent.Tools.OutputLimit.Result do
  @moduledoc "Bounded command output with explicit producer and capture completion facts."

  alias MingaAgent.Tool.Output

  @type status :: non_neg_integer() | :timeout | :terminated
  @type t :: %__MODULE__{
          output: binary(),
          status: status(),
          capture: Output.capture_status()
        }

  @enforce_keys [:output, :status, :capture]
  defstruct [:output, :status, :capture]

  @doc "Builds a command result owned by the output collector."
  @spec new(binary(), status(), Output.capture_status()) :: t()
  def new(output, status, capture) when is_binary(output) do
    %__MODULE__{output: output, status: status, capture: capture}
  end
end
