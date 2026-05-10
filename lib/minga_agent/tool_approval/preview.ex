defmodule MingaAgent.ToolApproval.Preview do
  @moduledoc """
  Structured, editor-safe preview shown on an inline tool approval card.
  """

  @typedoc "Structured preview kind for an approval card."
  @type kind :: :diff | :command | :target | :args

  @typedoc "A public approval preview rendered by editor frontends."
  @type t :: %__MODULE__{
          kind: kind(),
          summary: String.t(),
          lines: [String.t()]
        }

  @enforce_keys [:kind, :summary, :lines]
  defstruct [:kind, :summary, :lines]

  @doc "Creates an approval preview."
  @spec new(kind(), String.t(), [String.t()]) :: t()
  def new(kind, summary, lines)
      when kind in [:diff, :command, :target, :args] and is_binary(summary) and is_list(lines) do
    %__MODULE__{kind: kind, summary: summary, lines: lines}
  end
end
