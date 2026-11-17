defmodule MingaAgent.ToolApproval.Public do
  @moduledoc """
  Complete immutable approval data for editor and remote presentation.

  The target is the only approval identity. This value never contains the blocked worker's private reply PID.
  """

  alias MingaAgent.ToolApproval.Preview
  alias MingaAgent.ToolApproval.Target

  @derive JSON.Encoder
  @enforce_keys [:target, :name, :args, :preview]
  defstruct [:target, :name, :args, :preview]

  @type t :: %__MODULE__{
          target: Target.t(),
          name: String.t(),
          args: map(),
          preview: Preview.t()
        }

  @doc "Creates an editor-safe approval from its complete identity and preview."
  @spec new(Target.t(), String.t(), map(), Preview.t()) :: t()
  def new(%Target{} = target, name, args, %Preview{} = preview)
      when is_binary(name) and is_map(args) do
    %__MODULE__{target: target, name: name, args: args, preview: preview}
  end
end
