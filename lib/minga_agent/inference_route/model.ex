defmodule MingaAgent.InferenceRoute.Model do
  @moduledoc """
  One model a contributed route offers, with the limits and behavior Minga fixes into selection policy.

  `reasoning_levels` lists the thinking levels in display order; the first one is the default. `compaction`, `usage`, and `cost` tell the native loop whether the route can summarize history, whether it reports token usage, and whether requests are metered or covered by a subscription.
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

  @type compaction :: :native | :unsupported
  @type usage :: :tokens | :none
  @type cost :: :metered | :subscription

  @type t :: %__MODULE__{
          id: String.t(),
          display_name: String.t(),
          context_window: pos_integer(),
          max_output: pos_integer(),
          reasoning_levels: [String.t(), ...],
          tools?: boolean(),
          images_in?: boolean(),
          tool_result_images?: boolean(),
          compaction: compaction(),
          usage: usage(),
          cost: cost()
        }

  @type error :: {:invalid_model_field, atom()}

  @doc """
  Builds a validated model declaration.

  `tool_result_images?` requires `images_in?`, because a model that cannot read images cannot read them inside tool results either.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, error()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- field(attrs, :id, &present_string?/1),
         {:ok, display_name} <- field(attrs, :display_name, &present_string?/1),
         {:ok, context_window} <- field(attrs, :context_window, &positive_integer?/1),
         {:ok, max_output} <- field(attrs, :max_output, &positive_integer?/1),
         {:ok, reasoning_levels} <- field(attrs, :reasoning_levels, &reasoning_levels?/1),
         {:ok, tools?} <- field(attrs, :tools?, &is_boolean/1),
         {:ok, images_in?} <- field(attrs, :images_in?, &is_boolean/1),
         {:ok, tool_result_images?} <- field(attrs, :tool_result_images?, &is_boolean/1),
         :ok <- validate_tool_result_images(images_in?, tool_result_images?),
         {:ok, compaction} <- field(attrs, :compaction, &(&1 in [:native, :unsupported])),
         {:ok, usage} <- field(attrs, :usage, &(&1 in [:tokens, :none])),
         {:ok, cost} <- field(attrs, :cost, &(&1 in [:metered, :subscription])) do
      {:ok,
       %__MODULE__{
         id: id,
         display_name: display_name,
         context_window: context_window,
         max_output: max_output,
         reasoning_levels: Enum.uniq(reasoning_levels),
         tools?: tools?,
         images_in?: images_in?,
         tool_result_images?: tool_result_images?,
         compaction: compaction,
         usage: usage,
         cost: cost
       }}
    end
  end

  def new(_attrs), do: {:error, {:invalid_model_field, :attrs}}

  @doc "Revalidates a model struct returned by a route callback."
  @spec validate(term()) :: {:ok, t()} | {:error, error()}
  def validate(%__MODULE__{} = model), do: model |> Map.from_struct() |> new()
  def validate(_model), do: {:error, {:invalid_model_field, :struct}}

  @spec field(map(), atom(), (term() -> boolean())) :: {:ok, term()} | {:error, error()}
  defp field(attrs, key, valid?) do
    value = Map.get(attrs, key)

    if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_model_field, key}}
  end

  @spec validate_tool_result_images(boolean(), boolean()) :: :ok | {:error, error()}
  defp validate_tool_result_images(false, true),
    do: {:error, {:invalid_model_field, :tool_result_images?}}

  defp validate_tool_result_images(_images_in?, _tool_result_images?), do: :ok

  @spec present_string?(term()) :: boolean()
  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""

  @spec positive_integer?(term()) :: boolean()
  defp positive_integer?(value), do: is_integer(value) and value > 0

  @spec reasoning_levels?(term()) :: boolean()
  defp reasoning_levels?([_first | _rest] = levels), do: Enum.all?(levels, &present_string?/1)
  defp reasoning_levels?(_levels), do: false
end
