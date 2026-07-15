defmodule Minga.Extension.Instance.CleanupFailure do
  @moduledoc "Typed failed-cleanup phase with its authority-owned retry context."

  alias Minga.Extension.Instance.StopContext

  @enforce_keys [:reason, :retry]
  defstruct [:reason, :retry]

  @type t :: %__MODULE__{reason: term(), retry: StopContext.t()}

  @doc "Captures a cleanup failure and resumable stop context."
  @spec new(term(), StopContext.t()) :: t()
  def new(reason, retry), do: %__MODULE__{reason: reason, retry: retry}

  @doc "Replaces the externally reported reason after projection failure."
  @spec replace_reason(t(), term()) :: t()
  def replace_reason(failure, reason), do: %{failure | reason: reason}
end
