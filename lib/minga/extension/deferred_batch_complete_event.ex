defmodule Minga.Extension.DeferredBatchCompleteEvent do
  @moduledoc "Result of asynchronously loading one batch of deferred extensions."

  @enforce_keys [:count, :failures]
  defstruct [:count, :failures]

  @type failure :: %{extension: atom(), reason: term()}
  @type t :: %__MODULE__{count: non_neg_integer(), failures: [failure()]}

  @doc "Builds a deferred batch completion payload."
  @spec new(non_neg_integer(), [failure()]) :: t()
  def new(count, failures) when is_integer(count) and count >= 0 do
    %__MODULE__{count: count, failures: failures}
  end
end
