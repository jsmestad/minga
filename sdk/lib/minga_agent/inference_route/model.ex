defmodule MingaAgent.InferenceRoute.Model do
  @moduledoc """
  One model a contributed route offers. Minga fixes these fields into the selection policy.

  This is a compile-time stub.
  """

  @enforce_keys [
    :id,
    :display_name,
    :context_window,
    :max_output,
    :reasoning_levels,
    :tools?,
    :images_in?,
    :tool_result_images?,
    :compaction,
    :usage,
    :cost
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          display_name: String.t(),
          context_window: pos_integer(),
          max_output: pos_integer(),
          reasoning_levels: [String.t(), ...],
          tools?: boolean(),
          images_in?: boolean(),
          tool_result_images?: boolean(),
          compaction: :native | :unsupported,
          usage: :tokens | :none,
          cost: :metered | :subscription
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, {:invalid_model_field, atom()}}
  def new(_attrs), do: raise("minga_sdk is compile-time only")
end
