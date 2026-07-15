defmodule Minga.Extension.Instance.PhaseFailure do
  @moduledoc "Typed terminal failure context for crashed and load-error phases."

  @enforce_keys [:reason]
  defstruct [:reason]

  @type t :: %__MODULE__{reason: term()}

  @doc "Captures a terminal lifecycle reason."
  @spec new(term()) :: t()
  def new(reason), do: %__MODULE__{reason: reason}
end
